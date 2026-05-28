var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// .wrangler/tmp/bundle-Lji0TL/checked-fetch.js
var urls = /* @__PURE__ */ new Set();
function checkURL(request, init) {
  const url = request instanceof URL ? request : new URL(
    (typeof request === "string" ? new Request(request, init) : request).url
  );
  if (url.port && url.port !== "443" && url.protocol === "https:") {
    if (!urls.has(url.toString())) {
      urls.add(url.toString());
      console.warn(
        `WARNING: known issue with \`fetch()\` requests to custom HTTPS ports in published Workers:
 - ${url.toString()} - the custom port will be ignored when the Worker is published using the \`wrangler deploy\` command.
`
      );
    }
  }
}
__name(checkURL, "checkURL");
globalThis.fetch = new Proxy(globalThis.fetch, {
  apply(target, thisArg, argArray) {
    const [request, init] = argArray;
    checkURL(request, init);
    return Reflect.apply(target, thisArg, argArray);
  }
});

// .wrangler/tmp/bundle-Lji0TL/strip-cf-connecting-ip-header.js
function stripCfConnectingIPHeader(input, init) {
  const request = new Request(input, init);
  request.headers.delete("CF-Connecting-IP");
  return request;
}
__name(stripCfConnectingIPHeader, "stripCfConnectingIPHeader");
globalThis.fetch = new Proxy(globalThis.fetch, {
  apply(target, thisArg, argArray) {
    return Reflect.apply(target, thisArg, [
      stripCfConnectingIPHeader.apply(null, argArray)
    ]);
  }
});

// src/index.ts
var src_default = {
  async fetch(request, env) {
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
  }
};
async function handleChat(request, env) {
  const apiKey = env.GROQ_API_KEY || env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return new Response("Missing Groq/Anthropic API key", { status: 400 });
  }
  const rawBody = await request.text();
  let anthropicBody;
  try {
    anthropicBody = JSON.parse(rawBody);
  } catch (err) {
    return new Response("Invalid JSON", { status: 400 });
  }
  const openAIMessages = [];
  if (anthropicBody.system) {
    openAIMessages.push({
      role: "system",
      content: anthropicBody.system
    });
  }
  if (Array.isArray(anthropicBody.messages)) {
    for (const msg of anthropicBody.messages) {
      const role = msg.role;
      let content = "";
      if (typeof msg.content === "string") {
        content = msg.content;
      } else if (Array.isArray(msg.content)) {
        content = msg.content.map((block) => {
          if (block.type === "text") {
            return {
              type: "text",
              text: block.text
            };
          } else if (block.type === "image") {
            return {
              type: "image_url",
              image_url: {
                url: `data:${block.source.media_type};base64,${block.source.data}`
              }
            };
          }
          return block;
        });
      }
      openAIMessages.push({
        role,
        content
      });
    }
  }
  const model = "llama-3.2-11b-vision-preview";
  const groqBody = {
    model,
    messages: openAIMessages,
    max_tokens: anthropicBody.max_tokens || 1024,
    stream: anthropicBody.stream ?? true
  };
  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(groqBody)
  });
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Groq API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" }
    });
  }
  if (!groqBody.stream) {
    const groqJson = await response.json();
    const text = groqJson.choices?.[0]?.message?.content || "";
    const anthropicResponse = {
      id: groqJson.id || "msg_groq",
      type: "message",
      role: "assistant",
      content: [
        {
          type: "text",
          text
        }
      ],
      model,
      stop_reason: "end_turn"
    };
    return new Response(JSON.stringify(anthropicResponse), {
      status: 200,
      headers: { "content-type": "application/json" }
    });
  }
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  (async () => {
    let buffer = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done)
          break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed)
            continue;
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
                    text
                  }
                };
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicChunk)}

`));
              }
            } catch (e) {
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
                    text
                  }
                };
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicChunk)}

`));
              }
            } catch (e) {
            }
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
      "connection": "keep-alive"
    }
  });
}
__name(handleChat, "handleChat");
async function handleTranscribeToken(env) {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY || ""
      }
    }
  );
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" }
    });
  }
  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" }
  });
}
__name(handleTranscribeToken, "handleTranscribeToken");
async function handleTTS(request, env) {
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
        accept: "audio/mpeg"
      },
      body
    }
  );
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" }
    });
  }
  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg"
    }
  });
}
__name(handleTTS, "handleTTS");

// node_modules/wrangler/templates/middleware/middleware-ensure-req-body-drained.ts
var drainBody = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } finally {
    try {
      if (request.body !== null && !request.bodyUsed) {
        const reader = request.body.getReader();
        while (!(await reader.read()).done) {
        }
      }
    } catch (e) {
      console.error("Failed to drain the unused request body.", e);
    }
  }
}, "drainBody");
var middleware_ensure_req_body_drained_default = drainBody;

// node_modules/wrangler/templates/middleware/middleware-miniflare3-json-error.ts
function reduceError(e) {
  return {
    name: e?.name,
    message: e?.message ?? String(e),
    stack: e?.stack,
    cause: e?.cause === void 0 ? void 0 : reduceError(e.cause)
  };
}
__name(reduceError, "reduceError");
var jsonError = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } catch (e) {
    const error = reduceError(e);
    return Response.json(error, {
      status: 500,
      headers: { "MF-Experimental-Error-Stack": "true" }
    });
  }
}, "jsonError");
var middleware_miniflare3_json_error_default = jsonError;

// .wrangler/tmp/bundle-Lji0TL/middleware-insertion-facade.js
var __INTERNAL_WRANGLER_MIDDLEWARE__ = [
  middleware_ensure_req_body_drained_default,
  middleware_miniflare3_json_error_default
];
var middleware_insertion_facade_default = src_default;

// node_modules/wrangler/templates/middleware/common.ts
var __facade_middleware__ = [];
function __facade_register__(...args) {
  __facade_middleware__.push(...args.flat());
}
__name(__facade_register__, "__facade_register__");
function __facade_invokeChain__(request, env, ctx, dispatch, middlewareChain) {
  const [head, ...tail] = middlewareChain;
  const middlewareCtx = {
    dispatch,
    next(newRequest, newEnv) {
      return __facade_invokeChain__(newRequest, newEnv, ctx, dispatch, tail);
    }
  };
  return head(request, env, ctx, middlewareCtx);
}
__name(__facade_invokeChain__, "__facade_invokeChain__");
function __facade_invoke__(request, env, ctx, dispatch, finalMiddleware) {
  return __facade_invokeChain__(request, env, ctx, dispatch, [
    ...__facade_middleware__,
    finalMiddleware
  ]);
}
__name(__facade_invoke__, "__facade_invoke__");

// .wrangler/tmp/bundle-Lji0TL/middleware-loader.entry.ts
var __Facade_ScheduledController__ = class {
  constructor(scheduledTime, cron, noRetry) {
    this.scheduledTime = scheduledTime;
    this.cron = cron;
    this.#noRetry = noRetry;
  }
  #noRetry;
  noRetry() {
    if (!(this instanceof __Facade_ScheduledController__)) {
      throw new TypeError("Illegal invocation");
    }
    this.#noRetry();
  }
};
__name(__Facade_ScheduledController__, "__Facade_ScheduledController__");
function wrapExportedHandler(worker) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return worker;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  const fetchDispatcher = /* @__PURE__ */ __name(function(request, env, ctx) {
    if (worker.fetch === void 0) {
      throw new Error("Handler does not export a fetch() function.");
    }
    return worker.fetch(request, env, ctx);
  }, "fetchDispatcher");
  return {
    ...worker,
    fetch(request, env, ctx) {
      const dispatcher = /* @__PURE__ */ __name(function(type, init) {
        if (type === "scheduled" && worker.scheduled !== void 0) {
          const controller = new __Facade_ScheduledController__(
            Date.now(),
            init.cron ?? "",
            () => {
            }
          );
          return worker.scheduled(controller, env, ctx);
        }
      }, "dispatcher");
      return __facade_invoke__(request, env, ctx, dispatcher, fetchDispatcher);
    }
  };
}
__name(wrapExportedHandler, "wrapExportedHandler");
function wrapWorkerEntrypoint(klass) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return klass;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  return class extends klass {
    #fetchDispatcher = (request, env, ctx) => {
      this.env = env;
      this.ctx = ctx;
      if (super.fetch === void 0) {
        throw new Error("Entrypoint class does not define a fetch() function.");
      }
      return super.fetch(request);
    };
    #dispatcher = (type, init) => {
      if (type === "scheduled" && super.scheduled !== void 0) {
        const controller = new __Facade_ScheduledController__(
          Date.now(),
          init.cron ?? "",
          () => {
          }
        );
        return super.scheduled(controller);
      }
    };
    fetch(request) {
      return __facade_invoke__(
        request,
        this.env,
        this.ctx,
        this.#dispatcher,
        this.#fetchDispatcher
      );
    }
  };
}
__name(wrapWorkerEntrypoint, "wrapWorkerEntrypoint");
var WRAPPED_ENTRY;
if (typeof middleware_insertion_facade_default === "object") {
  WRAPPED_ENTRY = wrapExportedHandler(middleware_insertion_facade_default);
} else if (typeof middleware_insertion_facade_default === "function") {
  WRAPPED_ENTRY = wrapWorkerEntrypoint(middleware_insertion_facade_default);
}
var middleware_loader_entry_default = WRAPPED_ENTRY;
export {
  __INTERNAL_WRANGLER_MIDDLEWARE__,
  middleware_loader_entry_default as default
};
//# sourceMappingURL=index.js.map
