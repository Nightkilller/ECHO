//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI
import ApplicationServices

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var hasAutomationPermission = false
    @Published private(set) var hasDesktopPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// A small circular cropped/magnified snapshot of the folder or item being pointed at.
    @Published var magnifiedImage: NSImage?



    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private lazy var groqAPI: GroqAPI = {
        return GroqAPI(model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient()
    }()

    private let fallbackSynthesizer = NSSpeechSynthesizer()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all required permissions are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission && hasSpeechRecognitionPermission && hasAutomationPermission && hasDesktopPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        groqAPI.model = model
    }

    /// User preference for whether the Echo cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isEchoCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isEchoCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isEchoCursorEnabled")

    func setEchoCursorEnabled(_ enabled: Bool) {
        isEchoCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isEchoCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")


    }

    func start() {
        refreshAllPermissions()
        print("🔑 Echo start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Groq API
        _ = groqAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isEchoCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .echoDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        magnifiedImage = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        elevenLabsTTSClient.stopPlayback()
        fallbackSynthesizer.stopSpeaking()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAutomation = hasAutomationPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        let speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        hasSpeechRecognitionPermission = speechAuthStatus == .authorized

        hasAutomationPermission = WindowPositionManager.hasFinderAutomationPermission()
        hasDesktopPermission = WindowPositionManager.hasDesktopFolderPermission()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadAutomation != hasAutomationPermission
            || previouslyHadAll != allPermissionsGranted {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), speech: \(hasSpeechRecognitionPermission), screenContent: \(hasScreenContentPermission), automation: \(hasAutomationPermission), desktop: \(hasDesktopPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            if hasCompletedOnboarding && isEchoCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isEchoCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }


            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isEchoCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .echoDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            fallbackSynthesizer.stopSpeaking()
            clearDetectedElementLocation()


    


            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're echo, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - you are fully multilingual. you understand and can speak English, Hindi, and Hinglish (Hindi written in Roman/Latin script, e.g., "kaha hai folder?"). if the user speaks or asks in Hindi or Hinglish, respond to them in natural, casual Hinglish or Hindi. if they speak in English, reply in English.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element.
    CRITICAL: The label MUST be the exact, literal name of the target folder or item on screen (e.g. "KURSOR" or "Flipkart" or "Microsoft"). Never use generic labels like "folder" or "icon" or "element" when pointing to a folder, because the application uses this exact label name to dynamically query Finder and snap the cursor overlay to the exact pixel center of the folder icon.
    if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    agentic actions:
    you can open folders, close windows, minimize windows, maximize windows, tile windows left or right, and launch/open applications.
    - open a folder: if asked to open a specific folder (e.g. "open the folder KURSOR"), point to it [POINT:x,y:folderName] and append [RUN:open_folder:folderPath].
    - close a window: if asked to close a window/folder, append [RUN:close_folder] to point to the red close button and click it.
    - minimize a window: if asked to minimize a window, point to the yellow minimize button and append [RUN:minimize_window] to click it.
    - maximize/fill screen: if asked to maximize or fill screen, point to the green zoom button and append [RUN:maximize_window] to click it.
    - tile window left/right: if asked to tile left or right, point to the window and append [RUN:tile_left] or [RUN:tile_right].
    - open/launch application: if asked to open/launch an app (e.g. "open spotify"), point to its icon on screen (like in the Dock) and append [RUN:open_app:appName] (e.g. [RUN:open_app:Spotify]).

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks to open the folder KURSOR: "opening the kursor folder for you. [POINT:450,230:kursor][RUN:open_folder:/Users/adityagupta/Desktop/KURSOR]"
    - user asks to close this folder: "closing the folder window. [RUN:close_folder]"
    - user asks to minimize this window: "minimizing the window. [RUN:minimize_window]"
    - user asks to maximize this window: "maximizing the window to fill the screen. [RUN:maximize_window]"
    - user asks to shift this window to the left: "tiling this window to the left side of the screen. [POINT:400,300:window][RUN:tile_left]"
    - user asks to open Spotify from my dock: "opening spotify for you. [POINT:800,940:spotify][RUN:open_app:Spotify]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        fallbackSynthesizer.stopSpeaking()
        magnifiedImage = nil

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await groqAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Debug: log the full AI response so we can verify POINT/RUN tags
                print("🤖 AI full response: \(fullResponseText)")

                // Parse action commands and coordinates
                let actionResult = Self.parseActionCommands(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: actionResult.spokenText)
                let spokenText = parseResult.spokenText

                // Debug: log parsed results
                print("🎯 Parsed POINT coordinate: \(String(describing: parseResult.coordinate))")
                print("🎯 Parsed element label: \(String(describing: parseResult.elementLabel))")
                print("🎯 Parsed screen number: \(String(describing: parseResult.screenNumber))")
                print("🎯 Parsed open_folder path: \(String(describing: actionResult.openFolderPath))")
                print("🎯 Parsed close_folder: \(actionResult.shouldCloseFolder)")
                print("🎯 Parsed window_action: \(String(describing: actionResult.windowAction))")

                var actionFlightTarget: CGPoint? = nil

                // Determine flight targets based on close/minimize/maximize actions
                if actionResult.shouldCloseFolder {
                    if let closeBtnLoc = self.getWindowButtonLocation(attributeName: kAXCloseButtonAttribute) {
                        actionFlightTarget = closeBtnLoc
                        self.detectedElementBubbleText = "closing this!"
                        self.detectedElementDisplayFrame = self.screenFrameContainingPoint(closeBtnLoc)
                        print("🎯 Close button target set: \(closeBtnLoc)")
                    }
                } else if actionResult.windowAction == "minimize" {
                    if let minBtnLoc = self.getWindowButtonLocation(attributeName: kAXMinimizeButtonAttribute) {
                        actionFlightTarget = minBtnLoc
                        self.detectedElementBubbleText = "minimizing this!"
                        self.detectedElementDisplayFrame = self.screenFrameContainingPoint(minBtnLoc)
                        print("🎯 Minimize button target set: \(minBtnLoc)")
                    }
                } else if actionResult.windowAction == "maximize" {
                    if let zoomBtnLoc = self.getWindowButtonLocation(attributeName: kAXZoomButtonAttribute) {
                        actionFlightTarget = zoomBtnLoc
                        self.detectedElementBubbleText = "maximizing this!"
                        self.detectedElementDisplayFrame = self.screenFrameContainingPoint(zoomBtnLoc)
                        print("🎯 Zoom/Maximize button target set: \(zoomBtnLoc)")
                    }
                }

                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil || actionFlightTarget != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                var flightDuration: TimeInterval = 0.0

                if let actionFlightTarget = actionFlightTarget {
                    self.detectedElementScreenLocation = actionFlightTarget
                    flightDuration = self.calculateFlightDuration(to: actionFlightTarget)
                    
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64((flightDuration + 0.15) * 1_000_000_000))
                        if actionResult.shouldCloseFolder {
                            self.pressWindowButton(attributeName: kAXCloseButtonAttribute)
                        } else if actionResult.windowAction == "minimize" {
                            self.pressWindowButton(attributeName: kAXMinimizeButtonAttribute)
                        } else if actionResult.windowAction == "maximize" {
                            self.pressWindowButton(attributeName: kAXZoomButtonAttribute)
                        }
                    }
                } else if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    var rawX = pointCoordinate.x
                    var rawY = pointCoordinate.y

                    // Safeguard: If coordinates are normalized (0.0 to 1.0), scale them to pixels.
                    // This is extremely helpful for models that mix pixel space with normalized space.
                    if rawX > 0.0 && rawX <= 1.0 {
                        rawX = rawX * screenshotWidth
                    }
                    if rawY > 0.0 && rawY <= 1.0 {
                        rawY = rawY * screenshotHeight
                    }

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(rawX, screenshotWidth))
                    let clampedY = max(0, min(rawY, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    var finalLocation = globalLocation
                    var finalDisplayFrame = displayFrame
                    
                    if let label = parseResult.elementLabel {
                        let isFrontmostAppFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
                        var resolvedPos: CGPoint? = nil
                        
                        if isFrontmostAppFinder {
                            // If Finder is active, prioritize Finder Desktop icon snapping first
                            if let desktopPos = self.getDesktopIconPosition(named: label) {
                                resolvedPos = desktopPos
                                print("🎯 Pixel-perfect Finder Desktop Override (Finder Active): Snapped pointing target to Desktop icon \"\(label)\" at \(desktopPos)")
                            } else if let activeAppPos = self.getActiveAppUIElementLocation(named: label) {
                                resolvedPos = activeAppPos
                                print("🎯 Pixel-perfect Accessibility Override (Finder Fallback): Snapped pointing target to \"\(label)\" at \(activeAppPos)")
                            }
                        } else {
                            // If another app is active, prioritize Accessibility tree snapping first
                            if let activeAppPos = self.getActiveAppUIElementLocation(named: label) {
                                resolvedPos = activeAppPos
                                print("🎯 Pixel-perfect Accessibility Override: Snapped pointing target to \"\(label)\" at \(activeAppPos)")
                            } else if let desktopPos = self.getDesktopIconPosition(named: label) {
                                resolvedPos = desktopPos
                                print("🎯 Pixel-perfect Finder Desktop Override (Fallback): Snapped pointing target to Desktop icon \"\(label)\" at \(desktopPos)")
                            }
                        }
                        
                        if let resolvedPos = resolvedPos {
                            finalLocation = resolvedPos
                            if let primaryScreen = NSScreen.screens.first {
                                finalDisplayFrame = primaryScreen.frame
                            }
                        }
                    }

                    // Decide whether this is an action (open/close folder, minimize/maximize/tile).
                    // If it is an action, the user does not want the magnifying glass overlay to show.
                    let isAction = actionResult.openFolderPath != nil
                        || actionResult.shouldCloseFolder
                        || actionResult.windowAction == "minimize"
                        || actionResult.windowAction == "maximize"
                        || actionResult.windowAction == "tile_left"
                        || actionResult.windowAction == "tile_right"
                    
                    if isAction {
                        self.magnifiedImage = nil
                        print("🔍 Magnifier: Skipped magnification for folder action / window layout.")
                    } else {
                        // Crop the screenshot around the final resolved coordinate for screen magnification (folders/items search)
                        let fullCGImage = targetScreenCapture.cgImage
                        let displayLocalXForCrop = finalLocation.x - displayFrame.origin.x
                        let appKitYForCrop = finalLocation.y - displayFrame.origin.y
                        let displayLocalYForCrop = displayFrame.height - appKitYForCrop
                        
                        let pWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                        let pHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        let dWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                        let dHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                        
                        let pixelX = displayLocalXForCrop * (pWidth / dWidth)
                        let pixelY = displayLocalYForCrop * (pHeight / dHeight)
                        
                        let cropWidth: CGFloat = 160
                        let cropHeight: CGFloat = 160
                        let cropX = pixelX - cropWidth / 2.0
                        let cropY = pixelY - cropHeight / 2.0
                        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
                        
                        let imageWidth = CGFloat(fullCGImage.width)
                        let imageHeight = CGFloat(fullCGImage.height)
                        let clampedRect = CGRect(
                            x: max(0, min(cropRect.origin.x, imageWidth - cropRect.width)),
                            y: max(0, min(cropRect.origin.y, imageHeight - cropRect.height)),
                            width: min(cropRect.width, imageWidth),
                            height: min(cropRect.height, imageHeight)
                        )
                        
                        if let croppedCG = fullCGImage.cropping(to: clampedRect) {
                            let nsImg = NSImage(cgImage: croppedCG, size: NSSize(width: clampedRect.width, height: clampedRect.height))
                            self.magnifiedImage = nsImg
                            print("🔍 Magnifier: Successfully cropped final resolved coordinate at \(finalLocation) (pixels: \(pixelX), \(pixelY))")
                        } else {
                            self.magnifiedImage = nil
                        }
                    }

                    detectedElementScreenLocation = finalLocation
                    detectedElementDisplayFrame = finalDisplayFrame
                    print("🎯 Element pointing: (\(Int(rawX)), \(Int(rawY))) [original: (\(pointCoordinate.x), \(pointCoordinate.y))] → \"\(parseResult.elementLabel ?? "element")\"")
                    
                    if let openPath = actionResult.openFolderPath {
                        let duration = self.calculateFlightDuration(to: finalLocation)
                        flightDuration = duration
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
                            self.openFolder(at: openPath)
                        }
                    }
                    if let winAction = actionResult.windowAction {
                        let duration = self.calculateFlightDuration(to: finalLocation)
                        flightDuration = duration
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
                            self.performWindowAction(winAction)
                        }
                    }
                    if let openApp = actionResult.openAppName {
                        let duration = self.calculateFlightDuration(to: finalLocation)
                        flightDuration = duration
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
                            self.openApplication(named: openApp)
                        }
                    }
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element") — no coordinate to navigate to")
                    print("🎯 Note: Model may not have included [POINT:x,y:label] tag in response")
                    
                    if let openPath = actionResult.openFolderPath {
                        print("🎯 Opening folder without cursor flight: \(openPath)")
                        self.openFolder(at: openPath)
                    }
                    if let winAction = actionResult.windowAction {
                        print("🎯 Performing window action without cursor flight: \(winAction)")
                        self.performWindowAction(winAction)
                    }
                    if let openApp = actionResult.openAppName {
                        print("🎯 Opening application without cursor flight: \(openApp)")
                        self.openApplication(named: openApp)
                    }
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")


                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback(text: spokenText)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback(text: "Sorry, I had trouble processing that request.")
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isEchoCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks using macOS system TTS when ElevenLabs is down or not configured.
    private func speakCreditsErrorFallback(text: String = "") {
        let utterance = text.isEmpty ? "I'm all out of credits." : text
        fallbackSynthesizer.stopSpeaking()
        fallbackSynthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from anywhere in Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123.4,456.7:label] anywhere, tolerating arbitrary spacing, casing, integers, and floats
        let pattern = #"\[\s*POINT\s*:\s*(?:none|(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?:\s*:\s*([^\]:]*?))?(?:\s*:\s*screen\s*(\d+))?)\s*\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let nsRange = NSRange(responseText.startIndex..., in: responseText)
        
        // Find the first match to extract coordinates/details
        guard let firstMatch = regex.firstMatch(in: responseText, options: [], range: nsRange) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        var coordinate: CGPoint? = nil
        var elementLabel: String? = nil
        var screenNumber: Int? = nil

        // Check if groups 1 and 2 (x and y) are present (supports floats and integers)
        if firstMatch.numberOfRanges >= 3,
           let xRange = Range(firstMatch.range(at: 1), in: responseText),
           let yRange = Range(firstMatch.range(at: 2), in: responseText),
           let x = Double(responseText[xRange]),
           let y = Double(responseText[yRange]) {
            coordinate = CGPoint(x: x, y: y)
            elementLabel = "none" // default label
        }

        if firstMatch.numberOfRanges >= 4,
           let labelRange = Range(firstMatch.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if firstMatch.numberOfRanges >= 5,
           let screenRange = Range(firstMatch.range(at: 4), in: responseText) {
            screenNumber = Int(String(responseText[screenRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Strip ALL matching [POINT:...] tags from the spoken text so they aren't read out loud
        let cleanSpokenText = regex.stringByReplacingMatches(
            in: responseText,
            options: [],
            range: nsRange,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return PointingParseResult(
            spokenText: cleanSpokenText,
            coordinate: coordinate,
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Action Tag Parsing

    struct ActionParseResult {
        let spokenText: String
        let openFolderPath: String?
        let shouldCloseFolder: Bool
        let windowAction: String? // "maximize", "minimize", "tile_left", "tile_right", or nil
        let openAppName: String?
    }

    static func parseActionCommands(from responseText: String) -> ActionParseResult {
        var cleanText = responseText
        var openFolderPath: String? = nil
        var shouldCloseFolder = false
        var windowAction: String? = nil
        var openAppName: String? = nil

        // Match [RUN:open_folder:path] case-insensitively and with arbitrary spacing
        let openFolderPattern = #"\[\s*RUN\s*:\s*open_folder\s*:\s*([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: openFolderPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if let match = regex.firstMatch(in: cleanText, options: [], range: nsRange) {
                if let pathRange = Range(match.range(at: 1), in: cleanText) {
                    openFolderPath = String(cleanText[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:close_folder] case-insensitively and with arbitrary spacing
        let closeFolderPattern = #"\[\s*RUN\s*:\s*close_folder\s*\]"#
        if let regex = try? NSRegularExpression(pattern: closeFolderPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if regex.firstMatch(in: cleanText, options: [], range: nsRange) != nil {
                shouldCloseFolder = true
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:maximize_window] or [RUN:maximize_folder] case-insensitively and with arbitrary spacing
        let maximizePattern = #"\[\s*RUN\s*:\s*maximize_(?:window|folder)\s*\]"#
        if let regex = try? NSRegularExpression(pattern: maximizePattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if regex.firstMatch(in: cleanText, options: [], range: nsRange) != nil {
                windowAction = "maximize"
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:minimize_window] or [RUN:minimize_folder] case-insensitively and with arbitrary spacing
        let minimizePattern = #"\[\s*RUN\s*:\s*minimize_(?:window|folder)\s*\]"#
        if let regex = try? NSRegularExpression(pattern: minimizePattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if regex.firstMatch(in: cleanText, options: [], range: nsRange) != nil {
                windowAction = "minimize"
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:tile_left] case-insensitively and with arbitrary spacing
        let tileLeftPattern = #"\[\s*RUN\s*:\s*tile_left\s*\]"#
        if let regex = try? NSRegularExpression(pattern: tileLeftPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if regex.firstMatch(in: cleanText, options: [], range: nsRange) != nil {
                windowAction = "tile_left"
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:tile_right] case-insensitively and with arbitrary spacing
        let tileRightPattern = #"\[\s*RUN\s*:\s*tile_right\s*\]"#
        if let regex = try? NSRegularExpression(pattern: tileRightPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if regex.firstMatch(in: cleanText, options: [], range: nsRange) != nil {
                windowAction = "tile_right"
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        // Match [RUN:open_app:appName] case-insensitively and with arbitrary spacing
        let openAppPattern = #"\[\s*RUN\s*:\s*open_app\s*:\s*([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: openAppPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(cleanText.startIndex..., in: cleanText)
            if let match = regex.firstMatch(in: cleanText, options: [], range: nsRange) {
                if let appRange = Range(match.range(at: 1), in: cleanText) {
                    openAppName = String(cleanText[appRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: nsRange, withTemplate: "")
        }

        return ActionParseResult(
            spokenText: cleanText.trimmingCharacters(in: .whitespacesAndNewlines),
            openFolderPath: openFolderPath,
            shouldCloseFolder: shouldCloseFolder,
            windowAction: windowAction,
            openAppName: openAppName
        )
    }

    // MARK: - Finder Automation Helpers

    private func getFrontmostFinderCloseButtonAXElement() -> AXUIElement? {
        guard let finderApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            print("⚠️ Finder is not running")
            return nil
        }
        
        let appElement = AXUIElementCreateApplication(finderApp.processIdentifier)
        
        var windowsValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement], let frontWindow = windows.first else {
            print("⚠️ No Finder windows found")
            return nil
        }
        
        var closeButtonValue: AnyObject?
        let closeButtonResult = AXUIElementCopyAttributeValue(frontWindow, kAXCloseButtonAttribute as CFString, &closeButtonValue)
        guard closeButtonResult == .success, let closeButton = closeButtonValue else {
            print("⚠️ No close button found for frontmost Finder window")
            return nil
        }
        
        return (closeButton as! AXUIElement)
    }

    private func getFrontmostFinderWindowCloseButtonLocation() -> CGPoint? {
        guard let closeButton = getFrontmostFinderCloseButtonAXElement() else {
            return nil
        }
        
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(closeButton, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success else {
            print("⚠️ Failed to get position of close button")
            return nil
        }
        
        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(closeButton, kAXSizeAttribute as CFString, &sizeValue)
        var size = CGSize.zero
        if sizeResult == .success {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        
        let centerX = position.x + (size.width > 0 ? size.width / 2.0 : 7.0)
        let centerY = position.y + (size.height > 0 ? size.height / 2.0 : 7.0)
        
        // Convert from top-left screen coordinates (Accessibility) to AppKit bottom-left screen coordinates
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = primaryScreen.frame.height
        
        return CGPoint(x: centerX, y: mainScreenHeight - centerY)
    }

    private func getDesktopIconPosition(named label: String) -> CGPoint? {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty && cleanLabel.lowercased() != "none" else { return nil }
        
        let namesToTry = [cleanLabel, cleanLabel.uppercased(), cleanLabel.capitalized]
        
        for name in namesToTry {
            let appleScriptSource = """
            tell application "Finder"
                try
                    if exists item "\(name)" of desktop then
                        get position of item "\(name)" of desktop
                    else if exists folder "\(name)" of desktop then
                        get position of folder "\(name)" of desktop
                    end if
                end try
            end tell
            """
            
            guard let script = NSAppleScript(source: appleScriptSource) else { continue }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            
            if error == nil {
                if result.numberOfItems == 2,
                   let xDescriptor = result.atIndex(1),
                   let yDescriptor = result.atIndex(2) {
                    let x = CGFloat(xDescriptor.int32Value)
                    let y = CGFloat(yDescriptor.int32Value)
                    
                    guard let primaryScreen = NSScreen.screens.first else { continue }
                    let mainScreenHeight = primaryScreen.frame.height
                    
                    // Convert from Finder's top-left coordinates to AppKit bottom-left coordinates
                    let appKitLocation = CGPoint(x: x, y: mainScreenHeight - y)
                    print("🎯 Finder Desktop Matcher: found Desktop item \"\(name)\" at AppKit (\(appKitLocation.x), \(appKitLocation.y))")
                    return appKitLocation
                }
            } else {
                print("⚠️ Finder Desktop Matcher error for \"\(name)\": \(String(describing: error))")
            }
        }
        return nil
    }

    private func getFrontmostAppAXElement() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(frontmostApp.processIdentifier)
    }
    
    private func findUIElement(named targetText: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        // Limit depth to prevent infinite loops in malformed AX trees
        guard depth < 50 else { return nil }
        
        // Check title
        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        if titleResult == .success, let title = titleValue as? String {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cleanTargetText = targetText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if cleanTitle == cleanTargetText || cleanTitle.contains(cleanTargetText) {
                return element
            }
        }
        
        // Check description
        var descriptionValue: AnyObject?
        let descResult = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionValue)
        if descResult == .success, let description = descriptionValue as? String {
            if description.lowercased().contains(targetText.lowercased()) {
                return element
            }
        }
        
        // Check value
        var valueValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueValue)
        if valueResult == .success, let valueString = valueValue as? String {
            if valueString.lowercased().contains(targetText.lowercased()) {
                return element
            }
        }
        
        // Recursively search children
        var childrenValue: AnyObject?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenResult == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = findUIElement(named: targetText, in: child, depth: depth + 1) {
                    return found
                }
            }
        }
        
        return nil
    }
    
    private func getElementCenterLocation(_ element: AXUIElement) -> CGPoint? {
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success else { return nil }
        
        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var size = CGSize.zero
        if sizeResult == .success {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        
        let centerX = position.x + size.width / 2.0
        let centerY = position.y + size.height / 2.0
        
        // Convert from Accessibility (top-left origin) to AppKit bottom-left screen coordinates
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = primaryScreen.frame.height
        
        return CGPoint(x: centerX, y: mainScreenHeight - centerY)
    }
    
    private func getActiveAppUIElementLocation(named label: String) -> CGPoint? {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty && cleanLabel.lowercased() != "none" else { return nil }
        
        guard let appElement = getFrontmostAppAXElement() else { return nil }
        
        if let matchedElement = findUIElement(named: cleanLabel, in: appElement) {
            if let center = getElementCenterLocation(matchedElement) {
                // Reject center locations that are at or extremely close to (0.0, 0.0) as they are dummy/container AX elements
                if center.x < 0.1 && center.y < 0.1 {
                    print("⚠️ Accessibility Matcher: found active app UI element \"\(cleanLabel)\" but rejected coordinate near zero \(center)")
                    return nil
                }
                print("🎯 Accessibility Matcher: found active app UI element \"\(cleanLabel)\" at AppKit (\(center.x), \(center.y))")
                return center
            }
        }
        return nil
    }
    
    private func screenFrameContainingPoint(_ point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.frame ?? .zero
    }
    
    private func calculateFlightDuration(to targetLocation: CGPoint) -> TimeInterval {
        let mouseLocation = NSEvent.mouseLocation
        let distance = hypot(targetLocation.x - mouseLocation.x, targetLocation.y - mouseLocation.y)
        return min(max(Double(distance) / 800.0, 0.6), 1.4)
    }
    
    private func closeFrontmostFinderWindow(closeButton: AXUIElement?) {
        if let closeButton = closeButton {
            let actionResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if actionResult == .success {
                print("🎯 Closed Finder window via Accessibility kAXPressAction")
            } else {
                print("⚠️ Failed to press close button via Accessibility: \(actionResult)")
            }
        }
        
        // Fallback or double protection with AppleScript
        let appleScript = """
        tell application "Finder"
            if (count of windows) > 0 then
                close window 1
            end if
        end tell
        """
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let err = error {
                print("⚠️ AppleScript close window error: \(err)")
            } else {
                print("🎯 Closed Finder window via AppleScript fallback")
            }
        }
    }
    
    private func openFolder(at path: String) {
        var resolvedPath = path
        
        // Replace mock username with actual current user
        let currentUser = NSUserName()
        resolvedPath = resolvedPath.replacingOccurrences(of: "/Users/username/", with: "/Users/\(currentUser)/")
        
        // Expand tilde
        resolvedPath = (resolvedPath as NSString).expandingTildeInPath
        
        // Check if target folder exists
        if !FileManager.default.fileExists(atPath: resolvedPath) {
            // Robust fallback: try looking in user's actual Desktop or Desktop/KURSOR folders
            let folderName = (resolvedPath as NSString).lastPathComponent
            let possibleLocations = [
                "/Users/\(currentUser)/Desktop/\(folderName)",
                "/Users/\(currentUser)/Desktop/KURSOR/\(folderName)",
                "/Users/\(currentUser)/\(folderName)",
                "/Users/\(currentUser)/Downloads/\(folderName)"
            ]
            
            for loc in possibleLocations {
                if FileManager.default.fileExists(atPath: loc) {
                    resolvedPath = loc
                    break
                }
            }
        }
        
        let url = URL(fileURLWithPath: resolvedPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
            NSWorkspace.shared.open(url)
            print("🎯 Opened folder at path: \(resolvedPath) (isDirectory: \(isDirectory.boolValue))")
        } else {
            print("⚠️ Folder does not exist at: \(resolvedPath)")
            print("⚠️ Tried resolvedPath: \(resolvedPath), original: \(path)")
        }
    }

    private func getFrontmostAppWindowAXElement() -> AXUIElement? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        var targetPID: pid_t? = nil
        
        // 1. Try to find the frontmost active window using CGWindowListCopyWindowInfo (Z-ordered)
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] {
            for windowInfo in windowList {
                guard let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }
                guard windowOwnerPID != ourPID else { continue }
                
                // Ensure the window is in layer 0 (normal windows layer)
                guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int, windowLayer == 0 else { continue }
                
                // Ensure window size is reasonable (not 0x0 or tiny hidden/status windows)
                guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                      let width = bounds["Width"], let height = bounds["Height"],
                      width > 50, height > 50 else { continue }
                
                // Filter out standard macOS accessory/system processes
                if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
                    let ignoredNames = ["Window Server", "Dock", "SystemUIServer", "Echo", "leanring-buddy", "Notification Center", "ControlCenter", "System Settings", "System Preferences"]
                    if ignoredNames.contains(ownerName) {
                        continue
                    }
                }
                
                targetPID = windowOwnerPID
                break
            }
        }
        
        // 2. Fallback to the active application excluding ourselves
        if targetPID == nil {
            if let frontApp = NSWorkspace.shared.frontmostApplication, frontApp.processIdentifier != ourPID {
                targetPID = frontApp.processIdentifier
            } else {
                let apps = NSWorkspace.shared.runningApplications
                let regularApps = apps.filter { $0.activationPolicy == .regular && $0.processIdentifier != ourPID }
                if let activeRegularApp = regularApps.first(where: { $0.isActive }) {
                    targetPID = activeRegularApp.processIdentifier
                } else if let firstRegularApp = regularApps.first {
                    targetPID = firstRegularApp.processIdentifier
                }
            }
        }
        
        guard let pid = targetPID else { return nil }
        
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            print("🎯 Target application selected: \(app.localizedName ?? "unknown") (PID: \(pid))")
        } else {
            print("🎯 Target application selected PID: \(pid)")
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue)
        
        if result == .success, let win = windowValue {
            return (win as! AXUIElement)
        } else {
            var windowsValue: AnyObject?
            let winResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
            if winResult == .success, let windows = windowsValue as? [AXUIElement], let firstWin = windows.first {
                return firstWin
            }
        }
        return nil
    }

    private func getWindowButtonAXElement(attributeName: String) -> AXUIElement? {
        guard let window = getFrontmostAppWindowAXElement() else { return nil }
        
        var buttonValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(window, attributeName as CFString, &buttonValue)
        guard result == .success, let button = buttonValue else {
            return nil
        }
        return (button as! AXUIElement)
    }

    private func getWindowButtonLocation(attributeName: String) -> CGPoint? {
        guard let button = getWindowButtonAXElement(attributeName: attributeName) else { return nil }
        
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success else { return nil }
        
        var position = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &sizeValue)
        var size = CGSize.zero
        if sizeResult == .success {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        
        let centerX = position.x + (size.width > 0 ? size.width / 2.0 : 7.0)
        let centerY = position.y + (size.height > 0 ? size.height / 2.0 : 7.0)
        
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = primaryScreen.frame.height
        
        return CGPoint(x: centerX, y: mainScreenHeight - centerY)
    }

    private func pressWindowButton(attributeName: String) {
        if let button = getWindowButtonAXElement(attributeName: attributeName) {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result == .success {
                print("🎯 Successfully pressed window button \(attributeName)")
                return
            }
        }
        
        // Fallbacks if AX action performance failed or wasn't allowed:
        print("⚠️ AXPressAction failed for button \(attributeName), executing AppleScript fallback...")
        
        let ourPID = ProcessInfo.processInfo.processIdentifier
        var targetAppName = "Finder"
        
        // Find the active application name to target
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] {
            for windowInfo in windowList {
                guard let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }
                guard windowOwnerPID != ourPID else { continue }
                guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int, windowLayer == 0 else { continue }
                if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
                    let ignoredNames = ["Window Server", "Dock", "SystemUIServer", "Echo", "leanring-buddy", "Notification Center", "ControlCenter"]
                    if !ignoredNames.contains(ownerName) {
                        targetAppName = ownerName
                        break
                    }
                }
            }
        }
        
        if attributeName == kAXCloseButtonAttribute {
            let appleScript = """
            tell application "System Events"
                tell process "\(targetAppName)"
                    if (count of windows) > 0 then
                        click button 1 of window 1
                    end if
                end tell
            end tell
            """
            if let script = NSAppleScript(source: appleScript) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                if error != nil {
                    // Finder fallback
                    let finderScript = """
                    tell application "Finder"
                        if (count of windows) > 0 then
                            close window 1
                        end if
                    end tell
                    """
                    NSAppleScript(source: finderScript)?.executeAndReturnError(&error)
                }
            }
        } else if attributeName == kAXMinimizeButtonAttribute {
            let appleScript = """
            tell application "System Events"
                tell process "\(targetAppName)"
                    if (count of windows) > 0 then
                        set miniaturized of window 1 to true
                    end if
                end tell
            end tell
            """
            if let script = NSAppleScript(source: appleScript) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        } else if attributeName == kAXZoomButtonAttribute {
            let appleScript = """
            tell application "System Events"
                tell process "\(targetAppName)"
                    if (count of windows) > 0 then
                        set zoomed of window 1 to true
                    end if
                end tell
            end tell
            """
            if let script = NSAppleScript(source: appleScript) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
    }

    private func openApplication(named name: String) {
        print("🎯 Attempting to open application: \"\(name)\"")
        
        let capitalized = name.capitalized
        
        // Helper to unminimize windows of this app with native Genie/Scale system transitions
        let unminimizeHelper = { (appName: String) in
            let appleScript = """
            tell application "System Events"
                if exists process "\(appName)" then
                    tell process "\(appName)"
                        try
                            set miniaturizedWindows to every window whose miniaturized is true
                            repeat with win in miniaturizedWindows
                                set miniaturized of win to false
                            end repeat
                        end try
                        try
                            set collapsedWindows to every window whose collapsed is true
                            repeat with win in collapsedWindows
                                set collapsed of win to false
                            end repeat
                        end try
                    end tell
                end if
            end tell
            """
            if let script = NSAppleScript(source: appleScript) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
        
        // 1. Standard fullPath API to search Spotlight for application path by name
        if let path = NSWorkspace.shared.fullPath(forApplication: name) {
            let url = URL(fileURLWithPath: path)
            if NSWorkspace.shared.open(url) {
                print("🎯 Successfully opened application \"\(name)\" at path \(path) via fullPath")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    unminimizeHelper(name)
                    unminimizeHelper(capitalized)
                }
                return
            }
        }
        
        // Try capitalized name for fullPath lookup
        if let path = NSWorkspace.shared.fullPath(forApplication: capitalized) {
            let url = URL(fileURLWithPath: path)
            if NSWorkspace.shared.open(url) {
                print("🎯 Successfully opened application \"\(capitalized)\" at path \(path) via fullPath")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    unminimizeHelper(capitalized)
                    unminimizeHelper(name)
                }
                return
            }
        }
        
        // 2. Try NSWorkspace launchApplication
        if NSWorkspace.shared.launchApplication(name) {
            print("🎯 Successfully launched application \"\(name)\" via NSWorkspace.launchApplication")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                unminimizeHelper(name)
                unminimizeHelper(capitalized)
            }
            return
        }
        
        if NSWorkspace.shared.launchApplication(capitalized) {
            print("🎯 Successfully launched application \"\(capitalized)\" via NSWorkspace.launchApplication")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                unminimizeHelper(capitalized)
                unminimizeHelper(name)
            }
            return
        }
        
        // 3. Fallback: try opening from standard paths
        let possiblePaths = [
            "/Applications/\(name).app",
            "/Applications/\(capitalized).app",
            "/System/Applications/\(name).app",
            "/System/Applications/\(capitalized).app",
            "/Applications/Utilities/\(name).app",
            "/Applications/Utilities/\(capitalized).app"
        ]
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                if NSWorkspace.shared.open(url) {
                    print("🎯 Successfully opened application at path \(path)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        unminimizeHelper(name)
                        unminimizeHelper(capitalized)
                    }
                    return
                }
            }
        }
        
        // 4. Secondary fallback: AppleScript to activate
        let appleScript = "tell application \"\(name)\" to activate"
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil {
                print("🎯 Successfully activated application \"\(name)\" via AppleScript")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    unminimizeHelper(name)
                }
                return
            }
        }
        
        let capitalizedAppleScript = "tell application \"\(capitalized)\" to activate"
        if let script = NSAppleScript(source: capitalizedAppleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil {
                print("🎯 Successfully activated application \"\(capitalized)\" via AppleScript")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    unminimizeHelper(capitalized)
                }
                return
            }
        }
        
        print("⚠️ Failed to launch application \"\(name)\"")
    }

    private func performWindowAction(_ action: String) {
        guard let window = getFrontmostAppWindowAXElement() else {
            print("⚠️ Window action error: No frontmost window found")
            return
        }
        
        // Get the screen frame for the window
        guard let screen = NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame // frame excluding dock and menu bar
        
        var newPosition: CGPoint = visibleFrame.origin
        var newSize: CGSize = visibleFrame.size
        
        // Convert from AppKit (bottom-left) to AX (top-left) screen coordinates
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        if action == "maximize" {
            newPosition = CGPoint(x: visibleFrame.origin.x, y: mainScreenHeight - (visibleFrame.origin.y + visibleFrame.size.height))
            newSize = visibleFrame.size
        } else if action == "tile_left" {
            newSize = CGSize(width: visibleFrame.size.width / 2.0, height: visibleFrame.size.height)
            newPosition = CGPoint(x: visibleFrame.origin.x, y: mainScreenHeight - (visibleFrame.origin.y + visibleFrame.size.height))
        } else if action == "tile_right" {
            newSize = CGSize(width: visibleFrame.size.width / 2.0, height: visibleFrame.size.height)
            newPosition = CGPoint(x: visibleFrame.origin.x + newSize.width, y: mainScreenHeight - (visibleFrame.origin.y + visibleFrame.size.height))
        } else {
            return
        }
        
        // Set new position
        var posValue = newPosition
        if let axPosValue = AXValueCreate(.cgPoint, &posValue) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPosValue)
        }
        
        // Set new size
        var sizeValue = newSize
        if let axSizeValue = AXValueCreate(.cgSize, &sizeValue) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSizeValue)
        }
        
        print("🎯 Handled window action \"\(action)\"")
    }

}
