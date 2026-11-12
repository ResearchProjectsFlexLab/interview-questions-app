//
//  QuestionSession.swift
//  Interview Questions
//

import Foundation
import SwiftUI

@Observable
final class QuestionSession {
    enum Phase: Equatable {
        case ready         // before Start is pressed
        case instructions  // Start pressed, logging on; instructions shown until Start baseline is pressed
        case baseline      // 1-minute rest by the moonlit lake before the interview
        case countdown     // 3-2-1 before the first question
        case playing       // questions on screen
        case recovery      // 1-minute rest by the moonlit lake after the interview
        case finished      // Stop pressed (or recovery done), logging closed, log saved

        var isRest: Bool { self == .baseline || self == .recovery }
    }

    static let secondsPerQuestion = 20
    static let countdownSeconds = 3
    /// Baseline and recovery rest length.
    static let defaultRestSeconds = 60
    /// Normal resting breathing (12 per minute) for the paced rest scene — not slow paced
    /// breathing, which would raise HRV and stop being a resting baseline.
    static let inhaleSeconds: TimeInterval = 2
    static let exhaleSeconds: TimeInterval = 3
    static var breathCycle: TimeInterval { inhaleSeconds + exhaleSeconds }
    /// The whole interview ends after this long, even if questions remain.
    static let interviewTimeLimit: TimeInterval = 3 * 60

    let questions: [InterviewQuestion]
    private(set) var phase: Phase = .ready
    private(set) var index = 0
    private(set) var secondsRemaining = secondsPerQuestion
    private(set) var countdownValue = 0
    /// Whole seconds left in the interview (counts down from 3:00 once the first question appears).
    private(set) var interviewSecondsRemaining = Int(interviewTimeLimit)
    /// Every question that appeared, in order.
    private(set) var entries: [QuestionLogEntry] = []
    /// Every line written to the log (session start/stop, questions, skips, time-ups).
    private(set) var log: [LogLine] = []
    private(set) var sessionStartDate: Date?
    private(set) var sessionEndDate: Date?
    /// Where the log was written when the session stopped (Files › On My Apple Vision Pro › Interview Questions).
    private(set) var savedLogURL: URL?
    private(set) var saveError: String?

    /// When each boundary of the session happened (session, baseline, interview, recovery).
    private(set) var boundaries: [String: Date] = [:]
    static let boundaryKeys = [
        "session_start", "instructions_end", "baseline_start", "baseline_end",
        "interview_start", "interview_end", "recovery_start", "recovery_end", "session_end",
    ]

    /// True from the moment Start is pressed until Stop is pressed — i.e. while logging is on.
    var isRunning: Bool { phase != .ready && phase != .finished }

    /// Length of the baseline and recovery rests; 0 skips them (straight to the interview).
    let restSeconds: Int

    private let logDirectory: URL?
    private let timeLimit: TimeInterval
    /// When the current phase began (drives the breathing guide during rests).
    private(set) var phaseStartedAt: Date?
    private var pendingCountdown = countdownSeconds
    private var deadline: Date?
    /// When the interview ends regardless of how many questions are left.
    private var interviewDeadline: Date?
    private var questionShownAt: Date?

    /// `logDirectory` defaults to the app's Documents folder, which the Files app shows.
    /// `timeLimit` is the total interview length; the default is 3 minutes.
    /// `restSeconds` is the baseline and recovery rest length; the default is 1 minute, 0 skips them.
    init(
        questions: [InterviewQuestion] = QuestionBank.all,
        logDirectory: URL? = nil,
        timeLimit: TimeInterval = interviewTimeLimit,
        restSeconds: Int = defaultRestSeconds
    ) {
        self.questions = questions
        self.logDirectory = logDirectory
        self.timeLimit = timeLimit
        self.restSeconds = max(0, restSeconds)
        self.interviewSecondsRemaining = Int(timeLimit)
    }

    var current: InterviewQuestion? {
        guard phase == .playing, questions.indices.contains(index) else { return nil }
        return questions[index]
    }

    var isLastQuestion: Bool {
        phase == .playing && index == questions.count - 1
    }

    // MARK: - Start / Stop

    /// Starts logging immediately and shows the baseline instructions (or, with no rests,
    /// goes straight to the countdown). Pass `countdown: 0` to skip the 3-2-1.
    func start(at date: Date = .now, countdown: Int = countdownSeconds) {
        guard !isRunning, !questions.isEmpty else { return }
        index = 0
        entries = []
        log = []
        sessionStartDate = date
        sessionEndDate = nil
        savedLogURL = nil
        saveError = nil
        questionShownAt = nil
        secondsRemaining = Self.secondsPerQuestion
        interviewDeadline = nil
        interviewSecondsRemaining = Int(timeLimit)
        boundaries = ["session_start": date]
        pendingCountdown = countdown

        addLog(String(
            format: "SESSION START — %d questions, %ds each, %.0fs interview limit, %ds baseline and recovery rests",
            questions.count, Self.secondsPerQuestion, timeLimit, restSeconds
        ), at: date)
        QuestionLogger.roundStarted(questionCount: questions.count)

        if restSeconds > 0 {
            enterPhase(.instructions, at: date)
            deadline = nil
            addLog("INSTRUCTIONS SHOWN — waiting for Start baseline", at: date)
        } else {
            beginCountdown(at: date)
        }
    }

    /// The participant read the instructions and pressed Start baseline.
    func startBaseline(at date: Date = .now) {
        guard phase == .instructions else { return }
        addLog("PARTICIPANT PRESSED START BASELINE", at: date)
        boundaries["instructions_end"] = date
        beginRest(.baseline, at: date)
    }

    /// Ends the session, closes the log and saves it to Files automatically.
    func stop(at date: Date = .now) {
        guard isRunning else { return }
        let during = phaseName(phase)
        if phase == .playing {
            addLog("INTERVIEW END — stopped | questions shown: \(entries.count) of \(questions.count)", at: date)
            boundaries["interview_end"] = date
        } else if phase.isRest {
            boundaries["\(during)_end"] = date
        }
        finish(reason: "stopped during \(during)", at: date)
    }

    /// Returns to the welcome screen after a finished session.
    func restart() {
        guard !isRunning else { return }
        phase = .ready
        phaseStartedAt = nil
        index = 0
        secondsRemaining = Self.secondsPerQuestion
        countdownValue = 0
        deadline = nil
        interviewDeadline = nil
        interviewSecondsRemaining = Int(timeLimit)
    }

    // MARK: - Questions

    /// The participant pressed Next (or Finish on the last question).
    func advance(at date: Date = .now) {
        guard phase == .playing else { return }
        addLog("NEXT PRESSED [\(index + 1)] — after \(questionElapsedText(at: date))", at: date)
        moveOn(at: date)
    }

    func refresh(at date: Date) {
        guard isRunning, let deadline else { return }
        let remaining = deadline.timeIntervalSince(date)

        switch phase {
        case .baseline:
            if remaining <= 0 {
                addLog("BASELINE END", at: deadline)
                boundaries["baseline_end"] = deadline
                beginCountdown(at: deadline)
            }
            return
        case .recovery:
            if remaining <= 0 {
                addLog("RECOVERY END", at: deadline)
                boundaries["recovery_end"] = deadline
                finish(reason: "completed", at: deadline)
            }
            return
        case .countdown:
            if remaining <= 0 {
                beginQuestions(at: deadline)
            } else {
                let shown = max(1, Int(ceil(remaining)))
                if shown != countdownValue { countdownValue = shown }
            }
            return
        default:
            break
        }

        if let interviewDeadline, date >= interviewDeadline {
            addLog(String(format: "INTERVIEW TIME LIMIT — %.0fs reached during question %d", timeLimit, index + 1), at: date)
            endInterview(reason: "time limit reached", at: date)
            return
        }
        if let interviewDeadline {
            let left = max(0, Int(ceil(interviewDeadline.timeIntervalSince(date))))
            if left != interviewSecondsRemaining { interviewSecondsRemaining = left }
        }

        if remaining <= 0 {
            addLog("TIME UP [\(index + 1)] — \(Self.secondsPerQuestion)s limit reached", at: date)
            moveOn(at: date)
            return
        }
        let shown = min(Self.secondsPerQuestion, max(1, Int(ceil(remaining))))
        if shown != secondsRemaining {
            secondsRemaining = shown
        }
    }

    func fractionRemaining(at date: Date) -> Double {
        guard phase == .playing, let deadline else {
            return phase == .finished ? 0 : 1
        }
        let remaining = deadline.timeIntervalSince(date)
        return min(1, max(0, remaining / Double(Self.secondsPerQuestion)))
    }

    // MARK: - Rests and breathing guide

    /// Seconds into the current phase.
    func phaseElapsed(at date: Date = .now) -> TimeInterval {
        guard let phaseStartedAt else { return 0 }
        return max(0, date.timeIntervalSince(phaseStartedAt))
    }

    /// How far through the current rest (0…1).
    func restProgress(at date: Date = .now) -> Double {
        guard phase.isRest, restSeconds > 0 else { return 0 }
        return min(1, phaseElapsed(at: date) / Double(restSeconds))
    }

    /// Whole seconds left in the current rest.
    func restSecondsRemaining(at date: Date = .now) -> Int {
        guard phase.isRest else { return 0 }
        return max(0, Int(ceil(Double(restSeconds) - phaseElapsed(at: date))))
    }

    /// Breathing guide: 0 = fully out, 1 = fully in. Eased so the motion has no sudden changes.
    func breath(at date: Date = .now) -> Float {
        Self.breath(elapsed: phaseElapsed(at: date))
    }

    static func breath(elapsed: TimeInterval) -> Float {
        let t = elapsed.truncatingRemainder(dividingBy: breathCycle)
        let x: Double = t < inhaleSeconds ? t / inhaleSeconds : 1 - (t - inhaleSeconds) / exhaleSeconds
        return Float(x * x * (3 - 2 * x))
    }

    /// True while the guide is in the breathing-in part of the cycle.
    func isInhaling(at date: Date = .now) -> Bool {
        phaseElapsed(at: date).truncatingRemainder(dividingBy: Self.breathCycle) < Self.inhaleSeconds
    }

    // MARK: - Log

    var sessionDuration: TimeInterval {
        guard let sessionStartDate else { return 0 }
        return (sessionEndDate ?? .now).timeIntervalSince(sessionStartDate)
    }

    func logText(generatedAt: Date = .now) -> String {
        var text = QuestionLogFormat.text(lines: log, questionsShown: entries.count, generatedAt: generatedAt)
        // Boundaries in unix milliseconds, ready to line up with sensor data.
        text += "\nBoundaries (unix ms):\n"
        for key in Self.boundaryKeys {
            let value = boundaries[key].map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""
            text += "\(key)=\(value)\n"
        }
        return text
    }

    var suggestedLogFilename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "interview-log_\(f.string(from: sessionStartDate ?? .now))"
    }

    /// Writes the log into the app's Documents folder, which the Files app shows,
    /// so nothing is asked of the participant after Stop.
    func saveLogToFiles() {
        do {
            let folder = try logDirectory ?? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            var url = folder.appendingPathComponent(suggestedLogFilename).appendingPathExtension("txt")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(suggestedLogFilename)-\(n)").appendingPathExtension("txt")
                n += 1
            }
            try logText().write(to: url, atomically: true, encoding: .utf8)
            savedLogURL = url
            saveError = nil
        } catch {
            savedLogURL = nil
            saveError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func enterPhase(_ next: Phase, at date: Date) {
        phase = next
        phaseStartedAt = date
    }

    private func beginRest(_ rest: Phase, at date: Date) {
        let name = phaseName(rest)
        enterPhase(rest, at: date)
        deadline = date.addingTimeInterval(TimeInterval(restSeconds))
        boundaries["\(name)_start"] = date
        addLog(String(
            format: "%@ START — %ds rest | breathing %d/min (in %.0fs, out %.0fs) | scene: moonlit lake",
            name.uppercased(), restSeconds, Int(60 / Self.breathCycle), Self.inhaleSeconds, Self.exhaleSeconds
        ), at: date)
    }

    private func beginCountdown(at date: Date) {
        guard pendingCountdown > 0 else {
            beginQuestions(at: date)
            return
        }
        enterPhase(.countdown, at: date)
        countdownValue = pendingCountdown
        deadline = date.addingTimeInterval(TimeInterval(pendingCountdown))
        addLog("COUNTDOWN START — \(pendingCountdown)s", at: date)
    }

    private func beginQuestions(at date: Date) {
        enterPhase(.playing, at: date)
        boundaries["interview_start"] = date
        countdownValue = 0
        index = 0
        interviewDeadline = date.addingTimeInterval(timeLimit)
        interviewSecondsRemaining = Int(timeLimit)
        reveal(at: date)
    }

    private func moveOn(at date: Date) {
        let next = index + 1
        guard questions.indices.contains(next) else {
            endInterview(reason: "round complete", at: date)
            return
        }
        index = next
        reveal(at: date)
    }

    private func reveal(at date: Date) {
        deadline = date.addingTimeInterval(TimeInterval(Self.secondsPerQuestion))
        questionShownAt = date
        secondsRemaining = Self.secondsPerQuestion
        let question = questions[index]
        let entry = QuestionLogEntry(
            number: index + 1,
            appearedAt: date,
            tier: question.tier.title,
            difficulty: question.difficulty,
            prompt: question.prompt
        )
        entries.append(entry)
        addLog("NEW QUESTION [\(entry.number)] — \(entry.tier) | difficulty \(entry.difficulty) | \(entry.prompt)", at: date)
        QuestionLogger.appeared(entry)
    }

    /// The interview itself is over: rest for the recovery minute, or finish if there are no rests.
    private func endInterview(reason: String, at date: Date) {
        addLog("INTERVIEW END — \(reason) | questions shown: \(entries.count) of \(questions.count)", at: date)
        boundaries["interview_end"] = date
        interviewDeadline = nil
        interviewSecondsRemaining = 0
        secondsRemaining = 0
        if restSeconds > 0 {
            beginRest(.recovery, at: date)
        } else {
            finish(reason: reason, at: date)
        }
    }

    private func finish(reason: String, at date: Date) {
        enterPhase(.finished, at: date)
        boundaries["session_end"] = date
        deadline = nil
        interviewDeadline = nil
        interviewSecondsRemaining = 0
        secondsRemaining = 0
        countdownValue = 0
        sessionEndDate = date
        addLog(String(
            format: "SESSION STOP — %@ | questions shown: %d of %d | duration: %.0fs",
            reason, entries.count, questions.count, sessionDuration
        ), at: date)
        QuestionLogger.roundFinished(questionCount: entries.count)
        saveLogToFiles()
    }

    private func phaseName(_ phase: Phase) -> String {
        switch phase {
        case .ready: "ready"
        case .instructions: "instructions"
        case .baseline: "baseline"
        case .countdown: "countdown"
        case .playing: "interview"
        case .recovery: "recovery"
        case .finished: "finished"
        }
    }

    private func questionElapsedText(at date: Date) -> String {
        guard let questionShownAt else { return "0.0s" }
        return String(format: "%.1fs", date.timeIntervalSince(questionShownAt))
    }

    private func addLog(_ message: String, at date: Date) {
        log.append(LogLine(at: date, message: message))
    }
}
