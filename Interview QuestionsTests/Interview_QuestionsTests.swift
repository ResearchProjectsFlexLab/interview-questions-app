//
//  Interview_QuestionsTests.swift
//  Interview QuestionsTests
//
//  Created by Prisha Marpu on 10/9/26.
//

import Foundation
import Testing
@testable import Interview_Questions

@MainActor
struct Interview_QuestionsTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func questionsGetHarderInOrder() {
        let questions = QuestionBank.all
        #expect(questions.map(\.difficulty) == Array(1...questions.count))
        let tiers = questions.map(\.tier)
        #expect(tiers == tiers.sorted())
    }

    @Test func eachQuestionLastsTwentySeconds() {
        #expect(QuestionSession.secondsPerQuestion == 20)
    }

    @Test func startingLogsSessionStartAndTheQuestionThatAppears() {
        let session = makeSession()
        session.start(at: start, countdown: 0)

        #expect(session.isRunning)
        #expect(session.entries.count == 1)
        #expect(session.entries[0].number == 1)
        #expect(session.entries[0].prompt == "First prompt")
        #expect(session.entries[0].appearedAt == start)
        #expect(session.secondsRemaining == 20)
        #expect(session.log.first?.message.hasPrefix("SESSION START") == true)
    }

    @Test func startShowsCountdownWithLoggingOnBeforeFirstQuestion() {
        let session = makeSession()
        session.start(at: start)

        #expect(session.phase == .countdown)
        #expect(session.isRunning)
        #expect(session.countdownValue == 3)
        #expect(session.entries.isEmpty)
        #expect(session.log.map(\.message).map { $0.components(separatedBy: " —").first! } == ["SESSION START", "COUNTDOWN START"])

        session.refresh(at: start.addingTimeInterval(1.5))
        #expect(session.countdownValue == 2)

        session.refresh(at: start.addingTimeInterval(3))
        #expect(session.phase == .playing)
        #expect(session.entries.count == 1)
        #expect(session.entries[0].appearedAt == start.addingTimeInterval(3))
    }

    @Test func startingTwiceDoesNotLogTwice() {
        let session = makeSession()
        session.start(at: start, countdown: 0)
        session.start(at: start.addingTimeInterval(1), countdown: 0)
        #expect(session.entries.count == 1)
    }

    @Test func timerLogsTheNextQuestionWhenTwentySecondsElapse() {
        let session = makeSession()
        session.start(at: start, countdown: 0)

        session.refresh(at: start.addingTimeInterval(19.1))
        #expect(session.entries.count == 1)
        #expect(session.secondsRemaining == 1)

        session.refresh(at: start.addingTimeInterval(20))
        #expect(session.entries.count == 2)
        #expect(session.current?.prompt == "Second prompt")
        #expect(session.secondsRemaining == 20)
        #expect(session.log.contains { $0.message.hasPrefix("TIME UP [1]") })

        session.refresh(at: start.addingTimeInterval(21))
        #expect(session.entries.count == 2)
        #expect(session.secondsRemaining == 19)
    }

    @Test func skippingAheadLogsTheNewQuestion() {
        let session = makeSession()
        session.start(countdown: 0)
        session.advance()
        #expect(session.entries.map(\.prompt) == ["First prompt", "Second prompt"])
        #expect(session.log.contains { $0.message.hasPrefix("NEXT PRESSED [1]") })
    }

    @Test func stopEndsSessionAndSavesLogAutomatically() throws {
        let dir = try tempDirectory()
        let session = makeSession(logDirectory: dir)
        session.start(at: start, countdown: 0)
        session.stop(at: start.addingTimeInterval(7))

        #expect(session.phase == .finished)
        #expect(!session.isRunning)
        #expect(session.log.last?.message.hasPrefix("SESSION STOP — stopped") == true)

        let url = try #require(session.savedLogURL)
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("SESSION START"))
        #expect(saved.contains("First prompt"))
        #expect(saved.contains("SESSION STOP"))
        #expect(session.saveError == nil)
    }

    @Test func stoppingDuringCountdownStillSavesLog() throws {
        let session = makeSession(logDirectory: try tempDirectory())
        session.start(at: start)
        session.stop(at: start.addingTimeInterval(1))

        #expect(session.phase == .finished)
        #expect(session.entries.isEmpty)
        #expect(session.savedLogURL != nil)
    }

    @Test func interviewStopsAtThreeMinutesEvenWithQuestionsLeft() throws {
        let session = QuestionSession(logDirectory: try tempDirectory(), restSeconds: 0)
        #expect(QuestionSession.interviewTimeLimit == 180)
        #expect(session.questions.count * QuestionSession.secondsPerQuestion > 180)

        session.start(at: start)                                   // 3s countdown first
        let firstQuestion = start.addingTimeInterval(TimeInterval(QuestionSession.countdownSeconds))
        // Tick like the app does, every 0.1s, until just before the limit.
        var t = start
        while t < firstQuestion.addingTimeInterval(179.9) {
            t = t.addingTimeInterval(0.1)
            session.refresh(at: t)
        }
        #expect(session.phase == .playing)
        #expect(session.interviewSecondsRemaining == 1)

        session.refresh(at: firstQuestion.addingTimeInterval(180))

        #expect(session.phase == .finished)
        #expect(session.entries.count < session.questions.count)
        #expect(session.log.contains { $0.message.hasPrefix("INTERVIEW TIME LIMIT") })
        #expect(session.log.last?.message.hasPrefix("SESSION STOP — time limit reached") == true)
        #expect(session.savedLogURL != nil)
    }

    @Test func timeLimitCountsDownFromFirstQuestionNotStart() {
        let session = QuestionSession(questions: sampleQuestions(), logDirectory: try? tempDirectory(), timeLimit: 30, restSeconds: 0)
        session.start(at: start, countdown: 3)
        #expect(session.interviewSecondsRemaining == 30)

        session.refresh(at: start.addingTimeInterval(3))           // first question appears
        session.refresh(at: start.addingTimeInterval(13))
        #expect(session.interviewSecondsRemaining == 20)

        session.restart()   // no-op while running
        session.stop(at: start.addingTimeInterval(14))
        session.restart()
        #expect(session.interviewSecondsRemaining == 30)
    }

    @Test func finishingTheRoundSavesLogWithoutAnExtraQuestion() {
        let session = makeSession()
        session.start(at: start, countdown: 0)
        session.refresh(at: start.addingTimeInterval(20))
        session.refresh(at: start.addingTimeInterval(40))

        #expect(session.phase == .finished)
        #expect(session.entries.count == 2)
        #expect(session.current == nil)
        #expect(session.log.last?.message.hasPrefix("SESSION STOP — round complete") == true)
        #expect(session.savedLogURL != nil)
    }

    @Test func newRoundAfterStopStartsAFreshLog() {
        let session = makeSession()
        session.start(at: start, countdown: 0)
        session.stop(at: start.addingTimeInterval(2))
        session.restart()
        #expect(session.phase == .ready)

        session.start(at: start.addingTimeInterval(10), countdown: 0)
        #expect(session.entries.count == 1)
        #expect(session.log.count == 2)
        #expect(session.savedLogURL == nil)
    }

    @Test func logTextContainsEveryEvent() {
        let session = makeSession()
        session.start(at: start, countdown: 0)
        session.advance(at: start.addingTimeInterval(5))

        let generated = Date(timeIntervalSince1970: 1_700_000_100)
        let text = session.logText(generatedAt: generated)

        #expect(text.contains("Questions shown: 2"))
        #expect(text.contains("SESSION START"))
        #expect(text.contains("NEW QUESTION [1]"))
        #expect(text.contains("First prompt"))
        #expect(text.contains("NEW QUESTION [2]"))
        #expect(text.contains("Second prompt"))
        #expect(text.contains("Warm-up"))
        #expect(text.contains("Easy"))
        #expect(text.contains(QuestionLogFormat.stamp(generated)))
    }

    // MARK: - Baseline and recovery rests

    @Test func restsAreOneMinuteAtTwelveBreathsPerMinute() {
        #expect(QuestionSession.defaultRestSeconds == 60)
        #expect(60 / QuestionSession.breathCycle == 12)
        #expect(QuestionSession.breath(elapsed: 0) == 0)                                   // fully out
        #expect(QuestionSession.breath(elapsed: QuestionSession.inhaleSeconds) == 1)       // fully in
        #expect(QuestionSession.breath(elapsed: QuestionSession.breathCycle) == 0)         // out again
    }

    @Test func startShowsInstructionsAndWaitsForStartBaseline() {
        let session = QuestionSession(questions: sampleQuestions(), logDirectory: try? tempDirectory())
        session.start(at: start)
        #expect(session.phase == .instructions)
        #expect(session.isRunning)
        // Nothing moves on by itself while the instructions are up.
        session.refresh(at: start.addingTimeInterval(300))
        #expect(session.phase == .instructions)
        #expect(session.entries.isEmpty)
        #expect(session.log.last?.message.hasPrefix("INSTRUCTIONS SHOWN") == true)
    }

    @Test func fullSessionRunsBaselineInterviewThenRecovery() throws {
        let dir = try tempDirectory()
        let session = QuestionSession(questions: sampleQuestions(), logDirectory: dir)
        session.start(at: start)
        let pressed = start.addingTimeInterval(10)
        session.startBaseline(at: pressed)
        #expect(session.phase == .baseline)
        #expect(session.restSecondsRemaining(at: pressed.addingTimeInterval(15)) == 45)

        // Baseline lasts exactly a minute, then the 3-2-1 countdown, then the first question.
        session.refresh(at: pressed.addingTimeInterval(59.9))
        #expect(session.phase == .baseline)
        let baselineEnd = pressed.addingTimeInterval(60)
        session.refresh(at: baselineEnd)
        #expect(session.phase == .countdown)
        session.refresh(at: baselineEnd.addingTimeInterval(3))
        #expect(session.phase == .playing)
        #expect(session.entries.count == 1)

        // Finishing the interview starts the recovery rest instead of ending the session.
        let interviewEnd = baselineEnd.addingTimeInterval(20)
        session.advance(at: interviewEnd.addingTimeInterval(-10))
        session.advance(at: interviewEnd)
        #expect(session.phase == .recovery)
        #expect(session.isRunning)
        #expect(session.savedLogURL == nil)

        // Recovery lasts a minute, then the session ends and the log saves itself.
        session.refresh(at: interviewEnd.addingTimeInterval(60))
        #expect(session.phase == .finished)
        #expect(session.log.last?.message.hasPrefix("SESSION STOP — completed") == true)

        let saved = try String(contentsOf: try #require(session.savedLogURL), encoding: .utf8)
        for marker in ["SESSION START", "INSTRUCTIONS SHOWN", "PARTICIPANT PRESSED START BASELINE",
                       "BASELINE START", "BASELINE END", "COUNTDOWN START", "NEW QUESTION [1]",
                       "INTERVIEW END — round complete", "RECOVERY START", "RECOVERY END", "SESSION STOP",
                       "Boundaries (unix ms):"] {
            #expect(saved.contains(marker), "missing \(marker)")
        }
        func ms(_ d: Date) -> String { String(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
        #expect(saved.contains("baseline_start=\(ms(pressed))"))
        #expect(saved.contains("baseline_end=\(ms(baselineEnd))"))
        #expect(saved.contains("interview_end=\(ms(interviewEnd))"))
        #expect(saved.contains("recovery_end=\(ms(interviewEnd.addingTimeInterval(60)))"))
    }

    @Test func threeMinuteLimitLeadsIntoRecovery() {
        let session = QuestionSession(logDirectory: try? tempDirectory())
        session.start(at: start, countdown: 0)
        session.startBaseline(at: start)
        session.refresh(at: start.addingTimeInterval(60))          // baseline over, first question
        #expect(session.phase == .playing)
        var t = start.addingTimeInterval(60)
        while session.phase == .playing && t < start.addingTimeInterval(60 + 181) {
            t = t.addingTimeInterval(0.1)
            session.refresh(at: t)
        }
        #expect(session.phase == .recovery)
        #expect(session.log.contains { $0.message.hasPrefix("INTERVIEW END — time limit reached") })
    }

    @Test func stopDuringBaselineEndsSessionAndSaves() {
        let session = QuestionSession(questions: sampleQuestions(), logDirectory: try? tempDirectory())
        session.start(at: start)
        session.startBaseline(at: start)
        session.stop(at: start.addingTimeInterval(20))
        #expect(session.phase == .finished)
        #expect(session.entries.isEmpty)
        #expect(session.log.last?.message.hasPrefix("SESSION STOP — stopped during baseline") == true)
        #expect(session.savedLogURL != nil)
    }

    private func makeSession(logDirectory: URL? = nil) -> QuestionSession {
        let dir = logDirectory ?? (try? tempDirectory())
        return QuestionSession(questions: sampleQuestions(), logDirectory: dir, restSeconds: 0)
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("interview-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleQuestions() -> [InterviewQuestion] {
        [
            InterviewQuestion(difficulty: 1, tier: .warmup, prompt: "First prompt"),
            InterviewQuestion(difficulty: 2, tier: .easy, prompt: "Second prompt"),
        ]
    }
}
