import assert from "node:assert/strict";
import test from "node:test";
import { decideLayout } from "../src/layout.js";

test("wide layout always shows rail, detail, and inspector", () => {
  assert.deepEqual(decideLayout(120, false, true), {
    mode: "wide",
    showRail: true,
    showDetail: true,
    showInspector: true,
    inspectorOverlay: false,
  });
});

test("wide and standard layouts honor rail and inspector toggles", () => {
  assert.deepEqual(decideLayout(140, true, false, false), {
    mode: "wide",
    showRail: false,
    showDetail: true,
    showInspector: false,
    inspectorOverlay: false,
  });
  assert.equal(decideLayout(100, true, false, false).showRail, false);
});

test("standard layout uses an optional inspector overlay", () => {
  assert.equal(decideLayout(119, false, false).mode, "standard");
  assert.equal(decideLayout(80, true, true).inspectorOverlay, true);
  assert.equal(decideLayout(80, true, false).showInspector, false);
});

test("compact layout switches between overview and detail", () => {
  assert.deepEqual(decideLayout(79, false, false), {
    mode: "compact",
    showRail: true,
    showDetail: false,
    showInspector: false,
    inspectorOverlay: false,
  });

  const detail = decideLayout(40, true, true);
  assert.equal(detail.showRail, false);
  assert.equal(detail.showDetail, true);
  assert.equal(detail.showInspector, true);
});

test("manual dispatch can dedicate the content region at every supported width", () => {
  assert.equal(decideLayout(140, true, false, false).showRail, false);
  assert.equal(decideLayout(100, true, false, false).showRail, false);
  const compact = decideLayout(70, true, false, false);
  assert.equal(compact.showRail, false);
  assert.equal(compact.showDetail, true);
});
