import Darwin
import XCTest
@testable import WallpaperMachine

/// Fixed corpus and reproducible scoring. Only completed native validation + publication counts.
@MainActor
enum CreatorBenchmarkHarness {
    struct LiveTiming {
        let executionAllowance: TimeInterval
        let requestTimeout: TimeInterval

        init(_ environment: [String: String]) throws {
            func number(_ name: String, fallback: Double, range: ClosedRange<Double>) throws -> Double {
                guard let value = Double(environment[name] ?? String(fallback)), value.isFinite, range.contains(value)
                else { throw CreatorGenerationFailure.invalidRequest }
                return value
            }
            executionAllowance = try number("CREATOR_BENCHMARK_ALLOWANCE", fallback: 3600, range: 600...86_400)
            requestTimeout = try number("CREATOR_LIVE_TIMEOUT", fallback: 90, range: 5...600)
        }
    }

    // No free text from the model, profile or transport may enter terminal progress.
    static func progressLine(_ sample: Sample, index: Int) -> String {
        let failure = sample.failure.map { CreatorRepairIssue.Category(rawValue: $0)?.rawValue ?? "invalidRequest" } ?? "none"
        let seconds = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
            sample.elapsedSeconds.isFinite ? max(0, sample.elapsedSeconds) : 0)
        return "Creator benchmark \(index)/30 round=\(sample.round) passed=\(sample.passed) attemptCount=\(sample.requests) elapsedSeconds=\(seconds) failure=\(failure)"
    }

    static func emitProgress(_ sample: Sample, index: Int) {
        fputs(progressLine(sample, index: index) + "\n", stderr)
        fflush(stderr)
    }

    struct Prompt: Codable, Sendable {
        let id: String
        let template: String
        let complexity: String
        let text: String
    }
    static let prompts: [Prompt] = [
        .init(id: "G01", template: "gradient-v2", complexity: "simple", text: "用渐变模板创建缓慢移动的蓝紫色背景，低对比、少颗粒，不显示时钟。"),
        .init(id: "G02", template: "gradient-v2", complexity: "layered", text: "用渐变模板做暖橙与青色斜向波纹，明显呼吸感、轻微颗粒和暗角，运动柔和。"),
        .init(id: "G03", template: "gradient-v2", complexity: "boundary", text: "用渐变模板创建完全静止的黑夜色调，运动、波纹强度、颗粒与呼吸频率取允许的最小值。"),
        .init(id: "S01", template: "stars-v2", complexity: "simple", text: "用星空模板创建稀疏的深蓝星空，缓慢移动，不显示时钟。"),
        .init(id: "S02", template: "stars-v2", complexity: "layered", text: "用星空模板做紫色多层视差星海，大小错落、轻微拖尾和闪烁，偶尔流星，右下角小钟。"),
        .init(id: "S03", template: "stars-v2", complexity: "boundary", text: "用星空模板创建允许范围内最密集的四层星海，较长拖尾与高频流星，同时严格遵守整体资源上限。"),
        .init(id: "S04", template: "stars-v2", complexity: "unsupported-intent", text: "用星空模板表现仿佛随音乐呼吸的星光，只用允许的闪烁参数模拟节奏，不请求麦克风、网络、图片或新代码。"),
        .init(id: "C01", template: "clock-v2", complexity: "simple", text: "用时钟模板创建居中的二十四小时数字钟，显示秒和日期，深蓝背景、清晰易读。"),
        .init(id: "C02", template: "clock-v2", complexity: "layered", text: "用时钟模板创建左上角十二小时制暖色时钟，隐藏秒和日期，用内置等宽字体，微弱辉光和背景运动。"),
        .init(id: "C03", template: "clock-v2", complexity: "boundary", text: "用时钟模板创建适合竖屏的右下角时钟，缩放取允许最小值，静止背景，辉光取上限，不使用外来字体。")
    ]
    struct Sample: Codable, Sendable {
        let promptID: String
        let round: Int
        let passed: Bool
        let requests: Int
        let elapsedSeconds: Double
        let usage: [LLMResponse.Usage?]
        let reservedOutputTokens: Int
        let failure: String?
        var generatedTemplate: String? = nil
    }
    struct Distribution: Codable {
        let count: Int
        let minimum: Double?
        let p50: Double?
        let p95: Double?
        let maximum: Double?
        init(_ values: [Double]) {
            let sorted = values.sorted(); count = sorted.count
            minimum = sorted.first; maximum = sorted.last
            func percentile(_ p: Double) -> Double? {
                sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
            }
            p50 = percentile(0.5); p95 = percentile(0.95)
        }
    }
    struct Metrics: Codable {
        let samples: Int
        let firstPassRate: Double
        let repairedPassRate: Double
        let meetsRunnableTarget: Bool
        let requests: Int
        let reservedOutputTokens: Int
        let knownInputTokens: Int
        let knownOutputTokens: Int
        let knownTotalTokens: Int
        let unknownUsageAttempts: Int
        let incompleteUsageAttempts: Int
        let latency: Distribution
        let successfulLatency: Distribution
        init(_ rows: [Sample]) {
            samples = rows.count
            firstPassRate = rows.isEmpty ? 0 : Double(rows.filter { $0.passed && $0.requests == 1 }.count) / Double(rows.count)
            repairedPassRate = rows.isEmpty ? 0 : Double(rows.filter(\.passed).count) / Double(rows.count)
            meetsRunnableTarget = !rows.isEmpty && repairedPassRate >= 0.8
            requests = rows.reduce(0) { $0 + $1.requests }
            reservedOutputTokens = rows.reduce(0) { $0 + $1.reservedOutputTokens }
            let usages = rows.flatMap(\.usage)
            knownInputTokens = usages.compactMap { $0?.inputTokens }.reduce(0, +)
            knownOutputTokens = usages.compactMap { $0?.outputTokens }.reduce(0, +)
            knownTotalTokens = usages.compactMap { $0?.totalTokens }.reduce(0, +)
            unknownUsageAttempts = usages.filter { $0?.isUnknown != false }.count
            incompleteUsageAttempts = usages.filter { $0?.inputTokens == nil || $0?.outputTokens == nil || $0?.totalTokens == nil }.count
            latency = Distribution(rows.map(\.elapsedSeconds))
            successfulLatency = Distribution(rows.filter(\.passed).map(\.elapsedSeconds))
        }
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let corpusVersion = 1
        let mode: String
        let configuration: [String: String]
        let environment: [String: String]
        let prompts: [Prompt]
        let samples: [Sample]
        let metrics: Metrics
        let complete: Bool
        let targetEstablished: Bool
        let plannedSamples = 30
        let rateDenominator = "all observed samples, including failures; an incomplete run cannot establish the PRD target"
        let scope = "native static + offscreen WebKit + JPEG + temporary library; no visual preference or desktop score"
        let latencyMethod = "ContinuousClock wall time, nearest-rank p50/p95, failures retained"
        let tokenMethod = "reported known subtotals only; missing usage stays unknown; reserved output is not billed cost"
    }
    static func report(mode: String, configuration: [String: String] = [:], samples: [Sample]) -> Report {
        Report(mode: mode, configuration: configuration, environment: environment(), prompts: prompts,
               samples: samples, metrics: Metrics(samples), complete: samples.count == 30,
               targetEstablished: mode == "live" && samples.count == 30 && Metrics(samples).meetsRunnableTarget)
    }
    static func environment() -> [String: String] {
        var length = 0
        sysctlbyname("hw.model", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, min(length, 256)))
        let model = sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 ? String(cString: bytes) : "unknown"
        return ["macModel": model, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory), "validationSize": "960x540",
                "surface": "unattached WKWebView; no physical display measurement"]
    }
    static func attach<T: Encodable>(_ value: T, name: String, to test: XCTestCase) throws {
        let attachment = XCTAttachment(data: try CreatorPersistence.encode(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; test.add(attachment)
    }
    static func assertNoSecrets(in root: URL, forbidden: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let bytes = try Data(contentsOf: url)
            for value in forbidden {
                XCTAssertNil(bytes.range(of: Data(value.utf8)), "Credential residue in " + url.lastPathComponent, file: file, line: line)
            }
        }
    }
    static func runCase(_ prompt: Prompt, round: Int, store: CreatorRevisionStore, profile: ProviderProfile,
                        settings: CreatorSettingsStore, provider: LLMProvider, publisher: CreatorPublisher) async throws -> Sample {
        try Task.checkCancellation()
        let project = try await store.createProject(title: "Benchmark " + prompt.id)
        let flow = CreatorOrchestrator(store: store, generator: CreatorGenerator(store: store, settings: settings, provider: provider), publisher: publisher)
        let start = ContinuousClock.now
        var passed = false, failure: String?, generatedTemplate: String?
        do {
            let result = try await flow.createAndSave(.init(projectID: project.id, profileID: profile.id,
                configurationID: profile.configurationID, prompt: prompt.text, maxOutputTokens: 2048, maxRepairs: 2))
            generatedTemplate = result.sealed.templateID
            passed = true
        } catch {
            let issue = (error as? CreatorOrchestrator.Failure)?.issue ?? CreatorRepairIssue.from(error)
            if issue.category == .cancelled { throw CancellationError() }
            failure = issue.category.rawValue
        }
        let elapsed = start.duration(to: .now).components
        let turn = try await store.conversation(projectID: project.id).turns.last
        return Sample(promptID: prompt.id, round: round, passed: passed, requests: turn?.requestCount ?? 0,
            elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            usage: turn?.attempts.map(\.usage) ?? [], reservedOutputTokens: turn?.reservedOutputTokens ?? 0, failure: failure, generatedTemplate: generatedTemplate)
    }
}
