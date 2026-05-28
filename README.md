# 🎙️ Echo: Glowing Agentic Voice Companion for macOS

**Echo** is a premium, always-on visual AI companion that lives directly in your macOS menu bar. Driven by a simple keyboard shortcut, Echo looks at your displays, listens to your voice instructions, and translates your intentions into physical operating system interactions—like soaring across monitors to **open local directories** or programmatically **closing Finder windows** in synchronized landing.

Echo is built to feel alive. Rather than teleporting, your companion flies along smooth, physics-based arcing curves, rotating dynamically to align with its trajectory, and landing exactly on target.

---

## 💡 Inspiration & Attribution
Echo is a highly customized fork and comprehensive redesign of the original open-source **`learning-buddy`** assistant created by **Farza**, released under the permissive **MIT License**. 

While preserving the magical essence of an on-screen visual companion, we have re-engineered the application to feature a premium upfront permissions checklist, fully-offline local voice transcribing, an advanced agentic click-sync layer (closing windows & folder path resolutions), and stutter-proof `.common` run loop tracking.

---

## 🏗️ Technical Architecture & Pipeline

Echo's operation is structured into 6 highly optimized stages that run sequentially on the main thread and background tasks:

```
[User PTT Press] ────> [Audio Recording] ────> [Screen Capture] ────> [AI analysis & AX query]
                                                                                │
                                                                                ▼
[Execute Action] <──── [Time-Delayed Sync] <──── [Bezier swoop Flight] <──── [Coordinate Translation]
```

### 1. The Recording Phase (Voice-to-Text)
* **Components**: `BuddyDictationManager` & `AppleSpeechTranscriptionProvider`
* **Workflow**: When you hold down the push-to-talk hotkey (`Control + Option`), Echo opens an audio input channel via your microphone. It records your voice and streams the audio buffer to macOS's built-in, offline **Apple Speech framework**.
* **Purpose**: Transcribes your voice instruction into clean text locally on your device without sending voice files to third-party APIs.

### 2. Context Gathering (Screen Capture)
* **Components**: `CompanionScreenCaptureUtility`
* **Workflow**: The moment the hotkey is released, Echo immediately captures a high-resolution screenshot of all connected monitors using ScreenCaptureKit.
* **Purpose**: Captures the exact screen state (visible folders, active Finder windows, layouts) to send alongside your transcribed prompt.

### 3. Agentic Command Parsing (LLM & AXUIElement Queries)
* **Components**: `CompanionManager` & `GroqAPI`
* **Workflow**: The screenshots and text prompt are processed by your custom AI model on Groq. The AI parses the request and outputs action tags:
  * **To Open a Folder**: The AI determines where the folder icon is and appends `[POINT:x,y:label]` plus `[RUN:open_folder:folderPath]`.
  * **To Close a Window**: When you say "close the folder", Echo bypasses the AI's pixel-counting entirely and queries **macOS Accessibility APIs (`AXUIElement`)** to programmatically discover the exact global screen coordinates of the frontmost Finder window's red close button. It generates the flight coordinates automatically.

### 4. Coordinate Translation (Pixel to Screen Points)
* **Components**: `CompanionManager.swift`
* **Workflow**: Screen captures use raw **pixel space** (e.g., $2880 \times 1800$), whereas SwiftUI and macOS windows use **points space** (e.g., $1440 \times 900$) and have different origins (LLM uses top-left, AppKit uses bottom-left). Echo translates this:
  $$\text{LocalPointsX} = x_{\text{pixel}} \times \left(\frac{\text{Display Width}}{\text{Screenshot Width}}\right)$$
  $$\text{AppKitY} = \text{Display Height} - \left(y_{\text{pixel}} \times \frac{\text{Display Height}}{\text{Screenshot Height}}\right)$$
* **Purpose**: Maps coordinates precisely to your screen, accounting for multi-monitor setups.

### 5. Curved Swoop Flight (Bezier Animation)
* **Components**: `OverlayWindow.swift`
* **Workflow**: Once coordinates are translated, the blue triangle cursor triggers a quadratic Bezier flight path.
  * **Dynamic Timing**: Calculates the distance and determines flight duration (scaled between `0.6s` and `1.4s`).
  * **Tangent Rotation**: Rotates the triangle dynamically each frame to face its instantaneous direction of travel.
  * **Midpoint Pulse**: Scales the buddy up to `1.3x` at the apex of the arc before shrinking back to `1.0x` as it lands.
* **Starvation Prevention**: The tracking and flight timers are scheduled on `RunLoop.main` in `.common` mode. This ensures the buddy **never freezes** even if you are actively dragging windows, scrolling, or clicking other applications.

### 6. Land & Synchronized Action
* **Components**: `CompanionManager.swift`
* **Workflow**: Echo calculates the flight duration and schedules the target operation to trigger exactly `flightDuration + 0.15` seconds later.
  * **Open**: Lands beside the folder icon and opens the directory via `NSWorkspace.shared.open(url)`. Includes a path resolver that replaces generic `/Users/username/` references with your actual current home directory (`/Users/adityagupta/`) and searches your Desktop/workspace if folders are moved.
  * **Close**: Lands exactly on the red close button and triggers a native Accessibility press (`AXUIElementPerformAction`), closing the window cleanly.

---

## 🔒 Startup Checklist & Upfront Permissions

Rather than interrupting your workflow with arbitrary system requests, Echo groups all six essential security permissions into a polished, unified checklist during your first launch setup:

1. **Microphone**: Records your voice instructions.
2. **Speech Recognition**: Transcribes voice to text locally.
3. **Screen Recording**: Captures screenshots to let the AI see your workspace.
4. **Screen Content**: Persists capturing coordinates across multiple screens.
5. **Finder Automation**: Allows Echo to communicate with Finder windows.
6. **Desktop Folder Access**: Grants sandboxed clearance to open and query folders on your drive.

---

## 🛠️ Installation & Build

### Prerequisites
Make sure your Mac has Xcode command-line tools installed:
```bash
xcode-select --install
```

### Build Steps

1. Configure your custom Groq API credentials in `.env` inside the `echo` subfolder:
   ```env
   GROQ_API_KEY=your_groq_api_key
   MODEL_NAME=meta-llama/llama-4-scout-17b-16e-instruct
   ```
2. Build, package, and sign the application:
   ```bash
   ./build.sh
   ```
3. Launch your freshly built Echo application:
   ```bash
   open Echo.app
   ```

---

## 🎮 Detailed Usage Guide

### Getting Started (First Launch)
* When you launch `Echo.app`, the **Echo Settings** panel will automatically drop down beneath the menu bar icon.
* Click **"Grant"** next to each permission in the list.
* Press the **"Start"** button to play the welcome animation.

### Interacting with Echo
* **Hold `Control + Option`**: The buddy cursor transforms into a glowing, animated blue soundwave and begins listening.
* **Speak Your Instruction**: Keep holding the hotkey while speaking.
* **Release `Control + Option`**: The waveform transforms into a rotating blue processing spinner while the AI calculates the response, then the buddy takes off!

### Voice Command Examples:
* **Pointing**: *"Show me where my submission file is"* (The buddy swoops and points to the file).
* **Opening**: *"Open the folder KURSOR for me"* (The buddy flies to the folder and opens it inside Finder).
* **Closing**: *"Close this folder window"* (The buddy flies straight to the close button and closes it).

### Managing Settings & Quitting
* Click the **Echo** triangle in your menu bar to toggle settings, change the selected Groq LLM model, or click **"Quit Echo"** to exit.

---

## 🔧 Troubleshooting & FAQs

#### Q: The hotkey doesn't respond or wake up Echo?
If you recently re-built or signed the application, macOS might occasionally lock the Accessibility tap. To resolve this:
1. Open **System Settings > Privacy & Security > Accessibility**.
2. Toggle **Echo** off and back on again.

#### Q: The folder says it is opening but nothing happens?
* Check `clicky.log` in your project folder to see what path was resolved.
* Echo has a smart resolver that automatically searches `/Users/adityagupta/Desktop/` and `/Users/adityagupta/Desktop/KURSOR/` for your folder. Make sure the folder physically exists in one of these directories.

---

## 📝 License
This software is licensed under the **MIT License**. See the `LICENSE` file for details.
