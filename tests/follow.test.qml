// Run with:  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/follow.test.qml
// When a session's window follows its terminal to another workspace (ui/follow.js).
import QtQuick
import QtTest
import "../ui/follow.js" as Follow

TestCase {
    name: "FollowTerminal"

    function test_the_first_reading_never_moves_the_window() {
        var d = Follow.step(0, 11);
        compare(d.move, false);
        compare(d.last, 11);
    }
    function test_the_same_workspace_again_does_not_move_it() {
        var d = Follow.step(11, 11);
        compare(d.move, false);
        compare(d.last, 11);
    }
    function test_a_change_from_one_workspace_to_another_moves_it() {
        var d = Follow.step(11, 12);
        compare(d.move, true);
        compare(d.last, 12);
    }
    function test_an_unknown_reading_changes_nothing() {
        // no terminal found, or a special workspace: nothing moves and the last known one is kept
        [0, -1, -98, NaN, undefined].forEach(function (unknown) {
            var d = Follow.step(11, unknown);
            compare(d.move, false);
            compare(d.last, 11);
        });
        var first = Follow.step(0, 0);
        compare(first.move, false);
        compare(first.last, 0);
    }
    function test_dropping_out_and_coming_back_to_the_same_workspace_does_not_move_it() {
        var last = Follow.step(0, 11).last;
        last = Follow.step(last, 0).last;        // the strip state blinked out
        var d = Follow.step(last, 11);
        compare(d.move, false);
        compare(d.last, 11);
    }
    function test_dropping_out_and_coming_back_on_another_workspace_moves_it() {
        var last = Follow.step(0, 11).last;
        last = Follow.step(last, 0).last;
        compare(Follow.step(last, 12).move, true);
    }
}
