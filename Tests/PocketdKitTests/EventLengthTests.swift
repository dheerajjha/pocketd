import Foundation
import Testing
@testable import PocketdKit

/// Whether an event runs for the length the model wrote, or for an hour.
///
/// "Add dinner with Priya at 8pm" was written as a 480-minute event: Apple's
/// model fills `duration_minutes` nine times in ten when nobody said how long,
/// and no wording of its guidance stopped it. The number is now believed only
/// when the person's own words say how long, so most of this file is the table
/// of what counts as saying so — the sentences people type to add something on
/// one side, the ways a length is said on the other.
@Suite("Event length")
struct EventLengthTests {

    // MARK: - The words

    /// Each of these says how long, or when it ends.
    static let saysALength: [String] = [
        "Add a 90 minute workout at 6pm",
        "Add a 90-minute workout at 6pm",
        "add a ninety minute workout at six pm",
        "Add a workout at 6pm for 90 minutes",
        "Put the gym in for 2 hours at 6",
        "add a meeting at 3 for two hours",
        "Add a two-hour planning session tomorrow at 10",
        "Book a call at 4 for half an hour",
        "Add a half-hour call with Sam at 4",
        "Add a call at 4, an hour long",
        "Add an hour-long call at 4",
        "Add lunch with Sam for 45 min at 1",
        "Add standup at 9:30 for 15 mins",
        "add a 2hr review at 2pm",
        "add a 1h30 review at 2pm",
        "Add a 45m run at 7",
        "Add yoga for an hour and a half at 6pm",
        "Add piano for 1.5 hours at 5",
        "Add piano for 1½ hours at 5",
        "Add a couple of hours for the report at 10",
        "Add a 15 minute break at 11",
        "Add a 3 day conference starting Monday at 9",
        "Add a week's holiday from Monday at 9",
        "Add the offsite all day Friday",
        "Add an all-day workshop on Friday at 9",
        "Block out the whole afternoon for the report",
        "Add a trip to Brighton for the day tomorrow at 8",
        "Add a full day of training on Monday at 9",
        "Add a meeting from 2 to 4pm",
        "Add a meeting 2-4pm tomorrow",
        "Add a meeting 2pm\u{2013}4pm tomorrow",
        "Add a meeting 2 pm to 4 pm tomorrow",
        "Add work 9 to 5 tomorrow",
        "Add a meeting from 14:00 to 15:30",
        "Add revision from noon to 2",
        "Add a meeting between 2 and 4 tomorrow",
        "Add study at 7pm until 9",
        "Add study at 7pm till 9",
        "Add study at 7pm \u{2019}til 9",
        "Add the meeting at 3, it ends at 5",
        "Add the film at 8, it finishes around 10:30",
        "Add a call at 2 for an hour in room 5",
        // An offset AND a length: the length still counts.
        "Add the gym in 2 hours for an hour"
    ]

    /// None of these says how long. The first few are the commonest sentences
    /// anybody types to add something.
    static let saysNoLength: [String] = [
        "Add dinner with Priya at 8pm",
        "Add dinner with Priya at 8pm to my calendar",
        "Put lunch with Sam in for Friday at 1",
        "Add the dentist tomorrow at 9",
        "Schedule a call with Mum at 6pm",
        "Add team meeting every Tuesday at 10am",
        // A number with no unit is a party, not a length.
        "Add dinner for 2 at 8pm",
        "Book a table for four at 8",
        // A unit with no amount is a name.
        "Add happy hour with the team at 5pm",
        "Add office hours at 2pm",
        "Add a last minute prep call at 3",
        "Add the minutes review at 3",
        "Add Mother\u{2019}s Day lunch at 1pm",
        // An amount that says when it starts.
        "Add a call in 20 minutes",
        "Add a call in an hour",
        "Add a call in half an hour",
        "Add a call in a couple of hours",
        "Add a meeting 2 hours from now",
        "Add a reminder 30 minutes before the game",
        // A meeting with one person, written the ways people write it.
        "Add a 1-1 with Sam at 3",
        "Add a 1:1 with Sam at 3",
        "Add a 1-2-1 with Sam at 3",
        "Add a one to one with Sam at 3",
        // Numbers that are not lengths.
        "Add my 5k run at 7am",
        "Add mum\u{2019}s 60th at 7",
        "Add the review at the end of the day",
        "Add drinks at 6.30pm",
        ""
    ]

    @Test("a length the person said is seen, however they said it", arguments: EventLengthTests.saysALength)
    func lengthsAreSeen(_ sentence: String) {
        #expect(EventLength.statesALength(sentence), "\(sentence)")
    }

    @Test("a sentence that says nothing about length is not read as one", arguments: EventLengthTests.saysNoLength)
    func noLengthIsSeen(_ sentence: String) {
        #expect(!EventLength.statesALength(sentence), "\(sentence)")
    }

    // MARK: - The decision

    @Test("dinner at 8pm is an hour, whatever the model wrote")
    func inventedLengthsAreIgnored() {
        // The case this exists for, with the three lengths the model was seen
        // writing for it.
        for invented in [30, 120, 480] {
            #expect(EventLength.decide(stated: "Add dinner with Priya at 8pm", modelMinutes: invented) == 60, "\(invented)")
        }
        #expect(EventLength.decide(stated: "Add dinner with Priya at 8pm", modelMinutes: nil) == 60)
    }

    @Test("a length the person said is the model's to write")
    func statedLengthsAreKept() {
        #expect(EventLength.decide(stated: "Add a 90 minute workout at 6pm", modelMinutes: 90) == 90)
        #expect(EventLength.decide(stated: "Add a meeting at 3 for two hours", modelMinutes: 120) == 120)
        #expect(EventLength.decide(stated: "Add a 3 day conference starting Monday at 9", modelMinutes: 4320) == 4320)
        // Said, and left out anyway: the hour, never a number read out of the
        // words here.
        #expect(EventLength.decide(stated: "Add a 90 minute workout at 6pm", modelMinutes: nil) == 60)
        // The old guards still hold on a believed number.
        #expect(EventLength.decide(stated: "Add a 90 minute workout at 6pm", modelMinutes: 0) == 60)
        #expect(EventLength.decide(stated: "Add a 90 minute workout at 6pm", modelMinutes: 9_999_999) == PersonalDataWrites.maximumEventMinutes)
    }

    @Test("with no words to check, the model's length stands up to twelve hours")
    func noWordsKeepTheModelsLength() {
        // A network client, or a body called outside a conversation.
        #expect(EventLength.decide(stated: nil, modelMinutes: 480) == 480)
        #expect(EventLength.decide(stated: nil, modelMinutes: 720) == 720)
        #expect(EventLength.decide(stated: nil, modelMinutes: 721) == 60)
        #expect(EventLength.decide(stated: nil, modelMinutes: nil) == 60)
        #expect(EventLength.decide(stated: nil, modelMinutes: -5) == 60)
        // Blank is no words at all, not words that said nothing.
        #expect(EventLength.decide(stated: "   ", modelMinutes: 480) == 480)
    }

    @Test("the length is said the way a person would say it")
    func spokenLengths() {
        let expected: [(Int, String)] = [
            (1, "1 minute"), (15, "15 minutes"), (30, "30 minutes"), (45, "45 minutes"),
            (60, "an hour"), (75, "75 minutes"), (90, "90 minutes"), (120, "2 hours"),
            (150, "2 hours 30 minutes"), (480, "8 hours"), (1440, "a day"), (4320, "3 days")
        ]
        for (minutes, words) in expected {
            #expect(EventLength.spoken(minutes) == words, "\(minutes)")
        }
    }

    // MARK: - The seam

    @Test("the words a tool body reads are the latest thing this phone's person said")
    func whichWords() {
        let messages: [ChatMessage] = [
            .system("You are Pocketd."),
            .user("Add a 2 hour workshop at 3"),
            .assistant("Added it."),
            .user("Add dinner with Priya at 8pm")
        ]
        let fromThePhone = GenerationRequest(modelID: "", messages: messages, origin: .onDeviceChat)
        #expect(ToolContext.userText(of: fromThePhone) == "Add dinner with Priya at 8pm")

        // Another device's last message is whatever its software sent.
        let fromTheNetwork = GenerationRequest(modelID: "", messages: messages, origin: .network(host: "h", port: 1))
        #expect(ToolContext.userText(of: fromTheNetwork) == nil)

        let nothingSaid = GenerationRequest(modelID: "", messages: [.system("You are Pocketd.")], origin: .onDeviceChat)
        #expect(ToolContext.userText(of: nothingSaid) == nil)

        // Unbound, it is nothing — never somebody else's words.
        #expect(ToolContext.userText == nil)
    }
}
