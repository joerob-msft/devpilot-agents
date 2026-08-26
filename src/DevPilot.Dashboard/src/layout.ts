export type LayoutMode = "wide" | "standard" | "compact";

export interface LayoutDecision {
  mode: LayoutMode;
  showRail: boolean;
  showDetail: boolean;
  showInspector: boolean;
  inspectorOverlay: boolean;
}

export function decideLayout(
  width: number,
  detailOpen: boolean,
  inspectorOpen: boolean,
  railOpen = true,
): LayoutDecision {
  if (width >= 120) {
    return {
      mode: "wide",
      showRail: railOpen,
      showDetail: true,
      showInspector: inspectorOpen,
      inspectorOverlay: false,
    };
  }
  if (width >= 80) {
    return {
      mode: "standard",
      showRail: railOpen,
      showDetail: true,
      showInspector: inspectorOpen,
      inspectorOverlay: inspectorOpen,
    };
  }
  return {
    mode: "compact",
    showRail: !detailOpen,
    showDetail: detailOpen,
    showInspector: detailOpen && inspectorOpen,
    inspectorOverlay: detailOpen && inspectorOpen,
  };
}
