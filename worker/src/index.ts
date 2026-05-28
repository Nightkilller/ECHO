/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Groq, ElevenLabs, and AssemblyAI APIs.
 * Translates Anthropic format to Groq/OpenAI format dynamically.
 *
 * Routes:
 *   POST /chat  → Groq API (translated from Anthropic Messages schema)
 *   POST /tts   → ElevenLabs TTS API
 */

interface Env {
  ANTHROPIC_API_KEY?: string;
  GROQ_API_KEY?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const apiKey = env.GROQ_API_KEY || env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return new Response("Missing Groq/Anthropic API key", { status: 400 });
  }

  const rawBody = await request.text();
  let anthropicBody: any;
  try {
    anthropicBody = JSON.parse(rawBody);
  } catch (err) {
    return new Response("Invalid JSON", { status: 400 });
  }

  // Map Anthropic system prompt + messages to OpenAI/Groq format
  const openAIMessages: any[] = [];
  
  if (anthropicBody.system) {
    openAIMessages.push({
      role: "system",
      content: anthropicBody.system,
    });
  }

  if (Array.isArray(anthropicBody.messages)) {
    for (const msg of anthropicBody.messages) {
      const role = msg.role;
      let content: any = "";
      if (typeof msg.content === "string") {
        content = msg.content;
      } else if (Array.isArray(msg.content)) {
        content = msg.content.map((block: any) => {
          if (block.type === "text") {
            return {
              type: "text",
              text: block.text,
            };
          } else if (block.type === "image") {
            return {
              type: "image_url",
              image_url: {
                url: `data:${block.source.media_type};base64,${block.source.data}`,
              },
            };
          }
          return block;
        });
      }
      openAIMessages.push({
        role,
        content,
      });
    }
  }

  // Use llama-3.2-11b-vision-preview as it is Groq's fast vision model
  const model = "llama-3.2-11b-vision-preview";

  const groqBody = {
    model,
    messages: openAIMessages,
    max_tokens: anthropicBody.max_tokens || 1024,
    stream: anthropicBody.stream ?? true,
  };

  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(groqBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Groq API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  if (!groqBody.stream) {
    const groqJson: any = await response.json();
    const text = groqJson.choices?.[0]?.message?.content || "";
    const anthropicResponse = {
      id: groqJson.id || "msg_groq",
      type: "message",
      role: "assistant",
      content: [
        {
          type: "text",
          text,
        }
      ],
      model,
      stop_reason: "end_turn",
    };
    return new Response(JSON.stringify(anthropicResponse), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  // Streaming translation
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  (async () => {
    let buffer = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          if (trimmed.startsWith("data: ")) {
            const dataStr = trimmed.slice(6);
            if (dataStr === "[DONE]") {
              await writer.write(encoder.encode("data: [DONE]\n\n"));
              continue;
            }
            try {
              const parsed = JSON.parse(dataStr);
              const text = parsed.choices?.[0]?.delta?.content;
              if (text) {
                const anthropicChunk = {
                  type: "content_block_delta",
                  index: 0,
                  delta: {
                    type: "text_delta",
                    text,
                  },
                };
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicChunk)}\n\n`));
              }
            } catch (e) {
              // Ignore partial chunk JSON parse errors
            }
          }
        }
      }
      if (buffer.trim()) {
        const trimmed = buffer.trim();
        if (trimmed.startsWith("data: ")) {
          const dataStr = trimmed.slice(6);
          if (dataStr === "[DONE]") {
            await writer.write(encoder.encode("data: [DONE]\n\n"));
          } else {
            try {
              const parsed = JSON.parse(dataStr);
              const text = parsed.choices?.[0]?.delta?.content;
              if (text) {
                const anthropicChunk = {
                  type: "content_block_delta",
                  index: 0,
                  delta: {
                    type: "text_delta",
                    text,
                  },
                };
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicChunk)}\n\n`));
              }
            } catch (e) {}
          }
        }
      }
    } catch (err) {
      console.error("Stream translation error:", err);
    } finally {
      await writer.close();
    }
  })();

  return new Response(readable, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      "connection": "keep-alive",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY || "",
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;
  const apiKey = env.ELEVENLABS_API_KEY;

  if (!apiKey || !voiceId) {
    return new Response("ElevenLabs API key or voice ID is not configured.", { status: 400 });
  }

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": apiKey,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
