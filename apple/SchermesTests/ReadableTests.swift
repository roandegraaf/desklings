import Foundation
import Testing
@testable import Schermes

/// The cron reader and the activity sentences, against fixtures rather than a daemon. Every
/// reading below was checked against croner's own next runs, since croner is what the daemon
/// parses with and a sentence that disagrees with the expression is worse than none.

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Test func aCronReadsAsWhatItDoes() {
    let readings: [(String, String)] = [
        ("* * * * *", "every minute"),
        ("*/15 * * * *", "every 15 minutes"),
        ("0,30 * * * *", "every 30 minutes"),
        ("15,45 * * * *", "every 30 minutes"),
        ("0 * * * *", "every hour"),
        ("30 * * * *", "every hour at :30"),
        ("5,20 * * * *", "every hour at :05 and :20"),
        ("0 */2 * * *", "every 2 hours"),
        ("30 1-23/2 * * *", "every 2 hours from 01:30"),
        ("0 */6 * * *", "every day at 00:00, 06:00, 12:00 and 18:00"),
        ("0 9 * * *", "every day at 09:00"),
        ("30 8,17 * * *", "every day at 08:30 and 17:30"),
        ("0 9-17 * * *", "every hour from 09:00 to 17:00"),
        ("* 9 * * *", "every minute from 09:00 to 09:59"),
        ("*/15 9-17 * * 1-5", "every 15 minutes from 09:00 to 17:45 on weekdays"),
        ("0 9 * * 1-5", "on weekdays at 09:00"),
        ("0 9 * * MON-FRI", "on weekdays at 09:00"),
        ("0 9 * * mon", "on Mondays at 09:00"),
        ("0 9 * * 1,3,5", "on Mondays, Wednesdays and Fridays at 09:00"),
        ("0 10 * * 6,0", "on Saturdays and Sundays at 10:00"),
        ("0 9 * * 7", "on Sundays at 09:00"),
        ("0 9 * * 5-7", "on Fridays, Saturdays and Sundays at 09:00"),
        ("0 9 1 * *", "on the 1st of the month at 09:00"),
        ("0 9 1,15 * *", "on the 1st and 15th of the month at 09:00"),
        ("0 9 22,23 * *", "on the 22nd and 23rd of the month at 09:00"),
        // Two restricted day fields are either-or in croner, as in Vixie cron.
        ("0 9 1 * 1", "on the 1st of the month and on Mondays at 09:00"),
        ("0 9 1-31 * 1", "every day at 09:00"),
        ("0 0 1 1 *", "on the 1st of January at 00:00"),
        ("0 9 * 3-10 *", "every day at 09:00 from March to October"),
        ("0 9 * JAN,JUL *", "every day at 09:00 in January and July"),
        ("0 9 1 1,7 *", "on the 1st of the month at 09:00 in January and July"),
        ("@hourly", "every hour"),
        ("@daily", "every day at 00:00"),
        ("@weekly", "on Sundays at 00:00"),
        ("@monthly", "on the 1st of the month at 00:00"),
        ("@yearly", "on the 1st of January at 00:00"),
        ("0 0 9 * * *", "every day at 09:00"),
        ("0 0 9 * * * *", "every day at 09:00"),
    ]
    for (cron, words) in readings {
        #expect(cadence(cron) == words, "\(cron)")
    }
}

@Test func whatTheWordsCannotSayExactlyIsNotGuessedAt() {
    let unreadable = [
        // A step that does not divide the hour leaves a short gap at the top of it.
        "*/7 * * * *",
        "30 0 9 * * *",
        "0 0 9 * * * 2027",
        "0 9 L * *",
        "0 9 15W * *",
        "0 9 * * MON#2",
        "0 9 * * 5#L",
        // `?` is not `*` to croner: beside a restricted weekday it makes every day match.
        "0 9 ? * 1",
        "0 20 1 * +MON",
        "0 9 */2 * *",
        "0 9,12,15,18,21 * * *",
        // What croner itself refuses.
        "5/15 * * * *",
        "0 9 * * FRI-MON",
        "0 9 * *",
        "",
        // An ISO timestamp is a one-shot pattern to croner, so the daemon will store one.
        "2027-01-23T09:00:00",
    ]
    for cron in unreadable {
        #expect(cadence(cron) == nil, "\(cron)")
    }
}

@Test func everyKindOfEventReadsAsASentence() throws {
    let events: [ExecutionEvent] = try decode("""
    [
      {"id":1,"type":"state","data":{"from":"idle","to":"thinking"},"createdAt":0},
      {"id":2,"type":"tool_call","data":{"callId":"c1","tool":"run_command","command":"ls -la"},"createdAt":0},
      {"id":3,"type":"tool_result","data":{"callId":"c1","ok":true,"exitCode":0,"timedOut":false},"createdAt":0},
      {"id":4,"type":"tool_result","data":{"callId":"c2","ok":true,"exitCode":124,"timedOut":true},"createdAt":0},
      {"id":5,"type":"tool_call","data":{"callId":"c3","tool":"computer","action":"screenshot"},"createdAt":0},
      {"id":6,"type":"tool_result","data":{"callId":"c3","ok":true,"action":"screenshot","imageBytes":181204},"createdAt":0},
      {"id":7,"type":"tool_result","data":{"callId":"c4","ok":true,"action":"click"},"createdAt":0},
      {"id":8,"type":"tool_call","data":{"callId":"c5","tool":"browser","action":"navigate"},"createdAt":0},
      {"id":9,"type":"tool_result","data":{"callId":"c5","ok":true,"action":"navigate","host":"example.com","chars":3200},"createdAt":0},
      {"id":10,"type":"tool_call","data":{"callId":"c6","tool":"send_message"},"createdAt":0},
      {"id":11,"type":"tool_result","data":{"callId":"c6","ok":true,"to":"bravo","conversationId":3},"createdAt":0},
      {"id":12,"type":"tool_result","data":{"callId":"c7","ok":true,"worker":"scout-w1","dir":"/home/scout/w1"},"createdAt":0},
      {"id":13,"type":"tool_result","data":{"callId":"c8","ok":true,"host":"search.example","results":5},"createdAt":0},
      {"id":14,"type":"tool_result","data":{"callId":"c9","ok":true,"host":"example.com","status":200,"chars":5120},"createdAt":0},
      {"id":15,"type":"tool_result","data":{"callId":"c10","ok":true,"scope":"agent"},"createdAt":0},
      {"id":16,"type":"tool_result","data":{"callId":"c11","ok":true,"chars":1},"createdAt":0},
      {"id":17,"type":"tool_result","data":{"callId":"c12","ok":false,"error":"no search key"},"createdAt":0},
      {"id":18,"type":"tool_result","data":{"callId":"c13","ok":true,"schedules":1},"createdAt":0},
      {"id":19,"type":"tool_result","data":{"callId":"c14","ok":true,"schedule":4,"cron":"0 9 * * *"},"createdAt":0},
      {"id":20,"type":"tool_result","data":{"callId":"c15","ok":true,"schedule":4,"paused":true},"createdAt":0},
      {"id":21,"type":"tool_result","data":{"callId":"c16","ok":true,"schedule":4,"paused":false},"createdAt":0},
      {"id":22,"type":"tool_result","data":{"callId":"c17","ok":true,"schedule":4},"createdAt":0},
      {"id":23,"type":"tool_call","data":{"callId":"c18","tool":"mcp__files__read"},"createdAt":0},
      {"id":24,"type":"failure","data":{"message":"the provider answered 500"},"createdAt":0},
      {"id":25,"type":"restart","data":{"from":"using_terminal","interrupted":["c19","c20"]},"createdAt":0},
      {"id":26,"type":"restart","data":{"from":"thinking","worker":true},"createdAt":0},
      {"id":27,"type":"control","data":{"held":true},"createdAt":0},
      {"id":28,"type":"control","data":{"held":false},"createdAt":0},
      {"id":29,"type":"schedule_dropped","data":{"schedule":4,"cron":"2027-01-23T09:00:00"},"createdAt":0},
      {"id":30,"type":"state","data":{},"createdAt":0}
    ]
    """)

    #expect(events.map(sentence(for:)) == [
        "Now thinking",
        "Ran “ls -la”",
        "The command exited with code 0",
        "The command timed out",
        "Took a screenshot",
        "Got the screenshot",
        "Done",
        "Opened a page in the browser",
        "Got 3200 characters from example.com",
        "Called send_message",
        "Delivered a message to bravo",
        "Started task worker scout-w1",
        "Found 5 results on search.example",
        "Fetched example.com: HTTP 200, 5120 characters",
        "Saved to its agent memory",
        "Got 1 character back",
        "Failed: no search key",
        "Listed 1 schedule",
        "Scheduled 4 as “0 9 * * *”",
        "Paused schedule 4",
        "Resumed schedule 4",
        "Cancelled schedule 4",
        "Called mcp__files__read",
        "The turn failed: the provider answered 500",
        "The daemon restarted while it was using the terminal and cut off 2 tool calls",
        "The daemon restarted while it was thinking, so the worker was given up",
        "You took the mouse and keyboard",
        "You gave the mouse and keyboard back",
        "Dropped schedule 4 (“2027-01-23T09:00:00”): it has no next run left",
        "Changed state",
    ])
}
