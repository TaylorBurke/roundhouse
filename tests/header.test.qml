// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/header.test.qml
import QtQuick
import QtTest
import "../ui"

Item {
    width: 360; height: 100

    StripHeader {
        id: h
        width: 336
        ink: "#8d96ab"; inkStrong: "#d7dcea"; faint: "#4a5164"; accent: "#e0a458"; alert: "#f7768e"
    }
    SignalSpy { id: activated; target: h; signalName: "activate" }

    TestCase {
        name: "StripHeader"
        when: windowShown

        function init() {
            activated.clear();
            h.info = null; h.name = ""; h.model = ""; h.ended = false;
        }
        function strip(over) {
            var s = { project: "proj", task: "fixing the login redirect loop", phase: "working", running: 2, context: 40, pid: 1, address: "0x55aa11" };
            for (var k in over) s[k] = over[k];
            return s;
        }
        function item(n) { return findChild(h, n); }

        function test_without_a_strip_it_names_the_folder_and_model() {
            h.name = "alpha"; h.model = "claude-sonnet-5-5";
            compare(item("title").text, "alpha");
            compare(item("statusText").text, "claude-sonnet-5-5");
            compare(item("contextRow").visible, false);
            compare(item("dot").color.toString(), "#4a5164");
            h.ended = true;
            compare(item("statusText").text, "claude-sonnet-5-5  (ended)");
            compare(item("dot").color.toString(), "#f7768e");
            h.name = "";
            compare(item("title").text, "no session");
        }
        function test_working_shows_the_strips_text() {
            h.info = strip({});
            compare(item("title").text, "fixing the login redirect loop");
            compare(item("statusText").text, "2 tools running");
            compare(item("dot").color.toString(), "#e0a458");
            compare(item("contextRow").visible, true);
            compare(item("contextText").text, "40%");
            fuzzyCompare(item("contextFill").width, 44 * 0.4, 0.5);
            compare(item("contextFill").color.toString(), "#e0a458");
        }
        function test_one_tool_and_none() {
            h.info = strip({ running: 1 });
            compare(item("statusText").text, "1 tool running");
            h.info = strip({ running: 0 });
            compare(item("statusText").text, "");
            compare(item("statusText").visible, false);
        }
        function test_waiting_replaces_the_tools_and_the_bar() {
            h.info = strip({ phase: "waiting" });
            compare(item("statusText").text, "waiting for you");
            compare(item("statusText").color.toString(), "#f7768e");
            compare(item("dot").color.toString(), "#f7768e");
            compare(item("contextRow").visible, false);
        }
        function test_a_full_context_is_red_and_an_unknown_one_is_hidden() {
            h.info = strip({ context: 90 });
            compare(item("contextFill").color.toString(), "#f7768e");
            h.info = strip({ context: -1 });
            compare(item("contextRow").visible, false);
        }
        function test_title_falls_back_to_the_project_then_the_name() {
            h.name = "folder";
            h.info = strip({ task: "" });
            compare(item("title").text, "proj");
            h.info = strip({ task: "", project: "" });
            compare(item("title").text, "folder");
        }
        function test_click_focuses_only_when_there_is_a_window() {
            h.info = strip({});
            compare(h.canActivate, true);
            mouseClick(item("title"));
            compare(activated.count, 1);
            h.info = strip({ address: null });
            compare(h.canActivate, false);
            mouseClick(item("title"));
            compare(activated.count, 1);
            h.info = null;
            mouseClick(item("title"));
            compare(activated.count, 1);
        }
    }
}
