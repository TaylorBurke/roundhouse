.pragma library

// When a session's window should follow its terminal to another workspace.
//   last: the workspace the terminal was on at the previous reading (0: none yet)
//   now:  the workspace it is on now (0: not known: no terminal found, or a special workspace)
// Returns { move, last }: whether to move the window now, and the workspace to remember.
//
// The first reading never moves the window (it is wherever it was opened or placed), an unknown
// reading changes nothing, and only a real change from one known workspace to another moves it,
// so a window placed by hand stays put until the terminal moves.
function step(last, now) {
    if (!(now > 0)) return { move: false, last: last };
    return { move: last > 0 && now !== last, last: now };
}
