import type { DispatchBroker } from "./dispatch.js";
import type { EventTailer } from "./tailer.js";

export interface DashboardLifecycle {
  shutdownBroker: () => Promise<void>;
  onRendererDestroy: () => void;
}

export function createDashboardLifecycle(
  tailer: Pick<EventTailer, "stop">,
  broker?: Pick<DispatchBroker, "shutdown">,
  reportBrokerShutdownFailure: (error: unknown) => void = (error) => {
    process.stderr.write(
      `DevPilot dashboard broker shutdown failed: ${error instanceof Error ? error.message : String(error)}\n`,
    );
  },
): DashboardLifecycle {
  let brokerShutdown: Promise<void> | undefined;
  const shutdownBroker = (): Promise<void> => {
    brokerShutdown ??= broker?.shutdown() ?? Promise.resolve();
    return brokerShutdown;
  };
  return {
    shutdownBroker,
    onRendererDestroy: () => {
      void tailer.stop();
      void shutdownBroker().catch(reportBrokerShutdownFailure);
    },
  };
}
