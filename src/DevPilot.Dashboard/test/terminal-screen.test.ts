import assert from "node:assert/strict";
import test from "node:test";
import { TerminalScreen } from "./terminal-screen.js";

test("ConPTY screen reconstruction applies split cursor updates and erases rather than concatenating frames", () => {
  const screen = new TerminalScreen();
  screen.write("INSTANCES 0\r\nHelp opened");
  screen.write("\x1b[1;11");
  screen.write("H1\x1b[2;6Hclosed\x1b[K");
  assert.equal(screen.text(), "INSTANCES 1\nHelp closed");
  screen.write("\x1b[1;1H\x1b[2X");
  assert.equal(screen.text(), "  STANCES 1\nHelp closed");
  screen.write("\x1b]0;ignored");
  screen.write(" title\x07\x1b[?1049h\x1b[2;3HReady");
  assert.equal(screen.text(), "\n  Ready");
});

test("ConPTY full-frame text wraps at the terminal width before subsequent cell updates", () => {
  const screen = new TerminalScreen();
  screen.resize(5, 3);
  screen.write("ABCDE12345");
  screen.write("\x1b[2;2HX");
  assert.equal(screen.text(), "ABCDE\n1X345");
});

test("ConPTY DEC autowrap mode can disable and restore wrapping", () => {
  const screen = new TerminalScreen();
  screen.resize(5, 3);
  screen.write("\x1b[?7lABCDE123");
  assert.equal(screen.text(), "ABCD3");
  screen.write("\x1b[?7h45");
  assert.equal(screen.text(), "ABCD4\n5");
});

test("ConPTY cursor movement clamps to the last cell and cancels pending wrap", () => {
  const screen = new TerminalScreen();
  screen.resize(5, 3);
  screen.write("ABCDE\x1b[130CX");
  assert.equal(screen.text(), "ABCDX");
  screen.write("\x1b[2D!");
  assert.equal(screen.text(), "AB!DX");
  screen.write("\x1b[999;999HZ");
  assert.equal(screen.text(), "AB!DX\n\n    Z");
});

test("ConPTY line feeds scroll at the bottom without double wrapping", () => {
  const screen = new TerminalScreen();
  screen.resize(5, 2);
  screen.write("ABCDE\r\n12345\r\nX");
  assert.equal(screen.text(), "12345\nX");
  screen.write("\x1b[1;5HY\nZ");
  assert.equal(screen.text(), "1234Y\nX   Z");
});

test("ConPTY resize clips cells and cursor bounds before the next repaint", () => {
  const screen = new TerminalScreen();
  screen.resize(5, 3);
  screen.write("ABCDE\r\n12345\r\nabcde");
  screen.resize(3, 2);
  screen.write("X");
  assert.equal(screen.text(), "ABC\n12X");
  screen.resize(5, 3);
  screen.write("\x1b[3;1HReady");
  assert.equal(screen.text(), "ABC\n12X\nReady");
});

test("ConPTY split color and cursor sequences reconstruct the same screen as a whole frame", () => {
  const frame = "\x1b[?1049hINSTANCES 0\r\nHelp opened\x1b[1;11H1\x1b[2;6Hcl\x1b[31mos\x1b[1Cd\x1b[K";
  const whole = new TerminalScreen();
  whole.write(frame);
  for (let split = 0; split <= frame.length; split++) {
    const screen = new TerminalScreen();
    screen.write(frame.slice(0, split));
    screen.write(frame.slice(split));
    assert.equal(screen.text(), whole.text(), `split at ${split}`);
  }
  assert.equal(whole.text(), "INSTANCES 1\nHelp closed");
});
