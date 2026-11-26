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
    SignalSpy { id: dragSpy; target: sw; signalName: "dragStarted" }

    TestCase {
    name: "SessionSwitcher"
    when: windowShown

    function init() {
        pickSpy.clear(); followSpy.clear(); cycleSpy.clear(); dragSpy.clear();
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
    function test_dragging_the_name_moves_the_window_and_does_not_open_the_list() {
        mouseDrag(findChild(sw, "name"), 40, 12, 60, 30);
        compare(dragSpy.count, 1);
        compare(sw.open, false);
        mouseClick(findChild(sw, "name"));           // a plain click still opens the list
        compare(sw.open, true);
        compare(dragSpy.count, 1);
    }
    function test_dragging_a_gap_moves_the_window() {
        var prev = findChild(sw, "prev");
        mouseDrag(sw, prev.width + 3, 12, 60, 30);   // the 6 px between ‹ and the name
        compare(dragSpy.count, 1);
    }
    function test_the_buttons_do_not_drag_and_still_click() {
        mouseDrag(findChild(sw, "prev"), 9, 12, 60, 30);
        mouseDrag(findChild(sw, "next"), 9, 12, -60, 30);
        sw.pinned = true;
        mouseDrag(findChild(sw, "mode"), 26, 12, -60, 30);
        compare(dragSpy.count, 0);
        mouseClick(findChild(sw, "next"));
        compare(cycleSpy.count, 1);
        mouseClick(findChild(sw, "mode"));
        compare(followSpy.count, 1);
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
