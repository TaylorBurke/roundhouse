// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/switcher.test.qml
// Qt delivers these clicks to the real MouseAreas, as a pointer on screen would.
import QtQuick
import QtTest
import "../ui"

// The item under test sits in a root Item beside the TestCase, not inside it: children of a
// TestCase are not in the window's visual tree, so clicks would never reach them.
Item {
    width: 360; height: 200

    SessionSwitcher {
        id: sw
        width: 336
        sessions: [{ sid: "aaaaaaaa11", name: "alpha", idle: 3 }, { sid: "bbbbbbbb22", name: "beta", idle: 200 }, { sid: "cccccccc33", name: "gamma", idle: 4000 }]
        shown: "bbbbbbbb22"; shownName: "beta"; pinned: false
    }
    SignalSpy { id: pickSpy; target: sw; signalName: "pick" }
    SignalSpy { id: followSpy; target: sw; signalName: "follow" }
    SignalSpy { id: cycleSpy; target: sw; signalName: "cycle" }

    TestCase {
    name: "SessionSwitcher"
    when: windowShown

    function init() {
        pickSpy.clear(); followSpy.clear(); cycleSpy.clear();
        sw.open = false; sw.pinned = false; sw.shown = "bbbbbbbb22"; sw.shownName = "beta";
        sw.sessions = [{ sid: "aaaaaaaa11", name: "alpha", idle: 3 }, { sid: "bbbbbbbb22", name: "beta", idle: 200 }, { sid: "cccccccc33", name: "gamma", idle: 4000 }];
    }

    function test_text() {
        compare(findChild(sw, "name").text, "beta  2/3");
        compare(findChild(sw, "mode").text, "auto");
        sw.pinned = true;
        compare(findChild(sw, "mode").text, "pinned");
    }
    function test_arrows_cycle() {
        mouseClick(findChild(sw, "next"));
        mouseClick(findChild(sw, "prev"));
        compare(cycleSpy.count, 2);
        compare(cycleSpy.signalArguments[0][0], 1);
        compare(cycleSpy.signalArguments[1][0], -1);
    }
    function test_name_opens_list_and_row_picks() {
        compare(findChild(sw, "list").visible, false);
        mouseClick(findChild(sw, "name"));
        compare(sw.open, true);
        compare(findChild(sw, "list").visible, true);
        wait(50);                          // let the rows lay out, as a person's click would
        mouseClick(findChild(sw, "row0"));
        compare(pickSpy.count, 1);
        compare(pickSpy.signalArguments[0][0], "aaaaaaaa11");
        compare(sw.open, false);
    }
    function test_name_toggles_list() {
        mouseClick(findChild(sw, "name"));
        compare(sw.open, true);            // a click that did nothing would fail here
        mouseClick(findChild(sw, "name"));
        compare(sw.open, false);
    }
    function test_follow_row() {
        sw.pinned = true;
        mouseClick(findChild(sw, "name"));
        wait(50);
        mouseClick(findChild(sw, "followRow"));
        compare(followSpy.count, 1);
        compare(sw.open, false);
    }
    function test_pinned_label_follows() {
        mouseClick(findChild(sw, "mode"));
        compare(followSpy.count, 0);          // "auto" is not a button
        sw.pinned = true;
        mouseClick(findChild(sw, "mode"));
        compare(followSpy.count, 1);
    }
    function test_one_session_has_nothing_to_step_through() {
        sw.sessions = [{ sid: "bbbbbbbb22", name: "beta", idle: 5 }];
        compare(findChild(sw, "name").text, "beta");
        mouseClick(findChild(sw, "next"));
        mouseClick(findChild(sw, "prev"));
        compare(cycleSpy.count, 0);
    }
    function test_ended_session_still_named() {
        sw.sessions = [];
        sw.shownName = "delta";
        compare(findChild(sw, "name").text, "delta");
        sw.shownName = "";
        compare(findChild(sw, "name").text, "no session");
    }
}
}
