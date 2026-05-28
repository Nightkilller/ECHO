import Foundation
import AppKit

class Config {
    static let shared = Config()
    
    var groqApiKey: String = ""
    var modelName: String = "meta-llama/llama-4-scout-17b-16e-instruct"
    var elevenLabsApiKey: String = ""
    var elevenLabsVoiceId: String = "kPzsL2i3teMYv0FxEYQ6"
    
    // Audio Configurations
    let audioSampleRate: Double = 16000.0
    let audioChannels: Int = 1
    
    // UI/UX Configurations
    let cursorSize: CGFloat = 40.0
    let cursorColor: NSColor = NSColor(red: 0.0, green: 122.0/255.0, blue: 1.0, alpha: 1.0) // Apple Blue (#007AFF)
    let speechBubbleMaxWidth: CGFloat = 300.0
    
    // TTS Configurations
    var ttsVoice: String = "Samantha"
    var ttsRate: Float = 0.5 // AVSpeechUtterance rate is from 0.0 to 1.0 (0.5 is default/normal rate)
    
    // Path configurations
    var audioTempFileURL: URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("input_speech.wav")
    }
    
    var screenshotFileURL: URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("desktop_capture.jpg")
    }
    
    private init() {
        if let storedKey = UserDefaults.standard.string(forKey: "GROQ_API_KEY"), !storedKey.isEmpty {
            self.groqApiKey = storedKey
            print("🔑 Loaded Groq API Key from UserDefaults")
        }
        loadEnvFile()
    }
    
    func setGroqApiKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.groqApiKey = trimmedKey
        UserDefaults.standard.set(trimmedKey, forKey: "GROQ_API_KEY")
    }
    
    private func loadEnvFile() {
        // Search paths for .env
        let possiblePaths = [
            // 1. Executable directory
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/.env"),
            // 2. Main bundle resource directory
            Bundle.main.url(forResource: ".env", withExtension: nil),
            // 3. Current working directory
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            // 4. One folder up from current working directory (e.g. project root)
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../.env")
        ].compactMap { $0 }
        
        for url in possiblePaths {
            if FileManager.default.fileExists(atPath: url.path) {
                print("📝 Loading configuration from: \(url.path)")
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    parseEnvContent(content)
                    return
                }
            }
        }
        
        // Fallback to environment variables
        print("⚠️ No .env file found. Falling back to environment variables.")
        if self.groqApiKey.isEmpty, let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"] {
            self.groqApiKey = apiKey
        }
        if let model = ProcessInfo.processInfo.environment["MODEL_NAME"] {
            self.modelName = model
        }
        if let elApiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] {
            self.elevenLabsApiKey = elApiKey
        }
        if let elVoiceId = ProcessInfo.processInfo.environment["ELEVENLABS_VOICE_ID"] {
            self.elevenLabsVoiceId = elVoiceId
        }
    }
    
    private func parseEnvContent(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) // strip quotes
                
                switch key {
                case "GROQ_API_KEY":
                    if self.groqApiKey.isEmpty {
                        self.groqApiKey = value
                    }
                case "MODEL_NAME":
                    self.modelName = value
                case "TTS_VOICE":
                    self.ttsVoice = value
                case "TTS_RATE":
                    // Map Python rate (approx 200) to AVSpeechUtterance rate (0.0 to 1.0)
                    // If rate in env is "200" or similar, use default 0.5.
                    if let rawRate = Float(value) {
                        if rawRate > 1.0 {
                            self.ttsRate = 0.5 // default
                        } else {
                            self.ttsRate = rawRate
                        }
                    }
                case "ELEVENLABS_API_KEY":
                    self.elevenLabsApiKey = value
                case "ELEVENLABS_VOICE_ID":
                    self.elevenLabsVoiceId = value
                default:
                    break
                }
            }
        }
    }
}
