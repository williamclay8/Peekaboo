//
//  PeekabooAgentService+Enhancements.swift
//  PeekabooCore
//
//  Integration of agent enhancements:
//  - #1: Active Window Context Injection
//  - #2: Visual Verification Loop
//  - #3: Smart Screenshots
//

import CoreGraphics
import Foundation
import os.log
import PeekabooAutomation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    // MARK: - Enhancement Services

    /// Lazy-initialized desktop context service.
    var desktopContext: DesktopContextService {
        DesktopContextService(services: services)
    }

    /// Lazy-initialized smart capture service.
    var smartCapture: SmartCaptureService {
        SmartCaptureService(captureService: services.screenCapture)
    }

    /// Lazy-initialized action verifier.
    var actionVerifier: ActionVerifier {
        ActionVerifier(smartCapture: self.smartCapture)
    }

    // MARK: - Context Injection

    /// Inject desktop context into messages before an LLM turn.
    /// Call this before each model invocation when contextAware is enabled.
    func injectDesktopContext(
        into messages: inout [ModelMessage],
        options: AgentEnhancementOptions,
        tools: [AgentTool]) async
    {
        guard options.contextAware else { return }

        let hasClipboardTool = tools.contains(where: { $0.name == "clipboard" })
        let context = await desktopContext.gatherContext(includeClipboardPreview: hasClipboardTool)
        let contextString = self.desktopContext.formatContextForPrompt(context)

        // Insert as system message before the last user message
        let systemContent = ModelMessage.ContentPart.text(contextString)
        let contextMessage = ModelMessage(role: .system, content: [systemContent])

        // Find the last user message and insert before it
        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            messages.insert(contextMessage, at: lastUserIndex)
        } else {
            // No user message yet, append at end
            messages.append(contextMessage)
        }

        if isVerbose {
            logger.debug("Injected desktop context:\n\(contextString)")
        }
    }

    // MARK: - Tool Execution with Verification

    /// Execute a tool with optional verification.
    /// Wraps the standard tool execution to add post-action verification.
    func executeToolWithVerification(
        _ tool: AgentTool,
        arguments: AgentToolArguments,
        options: AgentEnhancementOptions) async throws -> (result: AnyAgentToolValue, verified: Bool)
    {
        // Execute the tool
        let executionContext = ToolExecutionContext(
            messages: [],
            model: currentModel ?? .openai(.gpt51),
            settings: GenerationSettings(maxTokens: 4096),
            sessionId: UUID().uuidString,
            stepIndex: 0)

        let result = try await tool.execute(arguments, context: executionContext)

        // Check if we should verify
        guard self.actionVerifier.shouldVerify(toolName: tool.name, options: options) else {
            return (result, false)
        }

        // Build action descriptor
        let targetElement = arguments["element"]?.stringValue ?? arguments["target"]?.stringValue
        let targetPoint = self.extractTargetPoint(from: arguments)

        let action = ActionDescriptor(
            toolName: tool.name,
            arguments: arguments.stringDictionary,
            targetElement: targetElement,
            targetPoint: targetPoint)

        // Verify the action
        let verification = try await actionVerifier.verify(action: action)

        if verification.success || verification.confidence < 0.5 {
            // Action verified or uncertain - proceed
            if isVerbose {
                logger.info("Action verified: \(tool.name) - \(verification.observation)")
            }
            return (result, true)
        }

        // Verification failed
        logger.warning("Action verification failed: \(verification.observation)")

        // Keep verification advisory only here. Re-running the tool would risk
        // repeating mutating desktop actions such as clicks, typing, or drags.
        return (result, false)
    }

    /// Annotate a tool result with verification metadata when verification is enabled.
    func annotateVerifiedToolResult(
        toolName: String,
        arguments: AgentToolArguments,
        result: AnyAgentToolValue,
        options: AgentEnhancementOptions) async -> AnyAgentToolValue?
    {
        guard self.actionVerifier.shouldVerify(toolName: toolName, options: options) else {
            return nil
        }

        let action = ActionDescriptor(
            toolName: toolName,
            arguments: arguments.stringDictionary,
            targetElement: arguments["element"]?.stringValue ?? arguments["target"]?.stringValue,
            targetPoint: self.extractTargetPoint(from: arguments))

        do {
            let verification = try await self.actionVerifier.verify(action: action)

            if self.isVerbose {
                self.logger.debug(
                    "Verification for \(toolName): success=\(verification.success), confidence=\(verification.confidence)")
            }

            return self.annotatedResult(result, with: verification)
        } catch {
            self.logger.warning("Action verification failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Smart Capture Integration

    /// Capture screen using smart capture if enabled.
    func captureScreenSmart(
        options: AgentEnhancementOptions,
        afterActionAt point: CGPoint? = nil) async throws -> SmartCaptureResult
    {
        if let point, options.regionFocusAfterAction {
            return try await self.smartCapture.captureAroundPoint(
                point,
                radius: options.regionCaptureRadius)
        }

        if options.smartCapture {
            return try await self.smartCapture.captureIfChanged(
                threshold: options.changeThreshold)
        }

        // Fall back to standard capture
        let captureResult = try await services.screenCapture.captureScreen(displayIndex: nil)
        let image = self.cgImage(from: captureResult)
        return SmartCaptureResult(
            image: image,
            changed: true,
            metadata: .fresh(capturedAt: Date()))
    }

    private func annotatedResult(
        _ result: AnyAgentToolValue,
        with verification: VerificationResult) -> AnyAgentToolValue
    {
        let verificationObject: [String: Any] = {
            var payload: [String: Any] = [
                "success": verification.success,
                "confidence": Double(verification.confidence),
                "observation": verification.observation,
                "should_retry": verification.shouldRetry,
            ]
            if let suggestion = verification.suggestion {
                payload["suggestion"] = suggestion
            }
            return payload
        }()

        do {
            let json = try result.toJSON()
            var payload = json as? [String: Any] ?? ["result": json]
            payload["verification"] = verificationObject
            return try AnyAgentToolValue.fromJSON(payload)
        } catch {
            return AnyAgentToolValue(object: [
                "result": result,
                "verification": AnyAgentToolValue(object: [
                    "success": AnyAgentToolValue(bool: verification.success),
                    "confidence": AnyAgentToolValue(double: Double(verification.confidence)),
                    "observation": AnyAgentToolValue(string: verification.observation),
                    "should_retry": AnyAgentToolValue(bool: verification.shouldRetry),
                    "suggestion": verification.suggestion.map { AnyAgentToolValue(string: $0) } ?? AnyAgentToolValue(null: ()),
                ]),
            ])
        }
    }

    /// Convert CaptureResult image data to CGImage.
    private func cgImage(from result: CaptureResult) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: result.imageData as CFData),
              let cgImage = CGImage(
                  pngDataProviderSource: dataProvider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent)
        else {
            return nil
        }
        return cgImage
    }

    // MARK: - Private Helpers

    private func extractTargetPoint(from arguments: AgentToolArguments) -> CGPoint? {
        // Try common argument patterns for position
        if let x = arguments["x"]?.doubleValue,
           let y = arguments["y"]?.doubleValue
        {
            return CGPoint(x: x, y: y)
        }

        if let position = arguments["position"]?.stringValue {
            // Parse "x,y" format
            let parts = position.split(separator: ",")
            if parts.count == 2,
               let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
            {
                return CGPoint(x: x, y: y)
            }
        }

        return nil
    }
}

// MARK: - AgentToolArguments Extension

extension AgentToolArguments {
    /// Convert to string dictionary for serialization.
    var stringDictionary: [String: String] {
        var dict: [String: String] = [:]
        for key in keys {
            if let value = self[key]?.stringValue {
                dict[key] = value
            } else if let value = self[key] {
                // Convert non-string values to string representation
                if let jsonData = try? JSONSerialization.data(withJSONObject: value.toJSON() as Any),
                   let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    dict[key] = jsonString
                }
            }
        }
        return dict
    }
}

// MARK: - Enhanced Streaming Loop Configuration

@available(macOS 14.0, *)
extension PeekabooAgentService {
    /// Configuration for streaming loop with enhancements.
    struct EnhancedStreamingConfiguration {
        let model: LanguageModel
        let tools: [AgentTool]
        let sessionId: String
        let eventHandler: EventHandler?
        let enhancementOptions: AgentEnhancementOptions

        init(
            model: LanguageModel,
            tools: [AgentTool],
            sessionId: String,
            eventHandler: EventHandler?,
            enhancementOptions: AgentEnhancementOptions = .default)
        {
            self.model = model
            self.tools = tools
            self.sessionId = sessionId
            self.eventHandler = eventHandler
            self.enhancementOptions = enhancementOptions
        }
    }

    /// Run the streaming loop with enhancements enabled.
    /// This wraps the standard streaming loop to add context injection and verification.
    func runEnhancedStreamingLoop(
        configuration: EnhancedStreamingConfiguration,
        maxSteps: Int,
        initialMessages: [ModelMessage],
        queueMode: QueueMode = .oneAtATime) async throws -> StreamingLoopOutcome
    {
        // Convert to standard configuration, passing through enhancement options
        let standardConfig = StreamingLoopConfiguration(
            model: configuration.model,
            tools: configuration.tools,
            sessionId: configuration.sessionId,
            eventHandler: configuration.eventHandler,
            enhancementOptions: configuration.enhancementOptions)

        // The shared streaming loop now handles post-tool verification. We still
        // rely on the shared streaming loop for context injection and keep this
        // wrapper as a thin forwarder to avoid double-injecting desktop state.

        return try await runStreamingLoop(
            configuration: standardConfig,
            maxSteps: maxSteps,
            initialMessages: initialMessages,
            queueMode: queueMode)
    }
}
