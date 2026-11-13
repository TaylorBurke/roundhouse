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
            compare(item("contextRow"), null);   // the map's hub already shows the context
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
        }
        function test_title_falls_back_to_the_project_then_the_name() {
            h.name = "folder";
            h.info = strip({ task: "" });
            compare(item("title").text, "proj");
            h.info = strip({ task: "", project: "" });
            compare(item("title").text, "folder");
        }
        function test_the_band_has_the_strips_divider_red_while_waiting() {
            h.info = strip({});
            compare(item("divider").height, 2);
            compare(item("divider").color.toString(), Qt.rgba(0xd7 / 255, 0xdc / 255, 0xea / 255, 0.2).toString());
            h.info = strip({ phase: "waiting" });
            compare(item("divider").color.toString(), "#f7768e");
        }
        function test_the_status_sits_under_the_title_and_the_band_grows_to_hold_it() {
            h.info = strip({});
            verify(item("status").y >= item("title").y + item("title").height);
            verify(h.height >= item("status").y + item("status").height + 2);
            var withStatus = h.height;
            h.info = strip({ running: 0 });
            compare(item("status").visible, false);
            verify(h.height < withStatus);
        }
        function test_a_long_title_wraps_to_two_lines_and_no_more() {
            h.info = strip({ task: "refactoring the whole session lifecycle so a long title is shown on two lines instead of being cut off after a dozen characters and never read" });
            compare(item("title").lineCount, 2);
            h.info = strip({ task: "short" });
            compare(item("title").lineCount, 1);
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
