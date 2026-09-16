import type { DispatchBroker } from "./dispatch.js";
import type { EventTailer } from "./tailer.js";

export interface DashboardLifecycle {
  shutdownTailer: () => Promise<void>;
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
  let tailerShutdown: Promise<void> | undefined;
  let brokerShutdown: Promise<void> | undefined;
  const shutdownTailer = (): Promise<void> => {
    tailerShutdown ??= tailer.stop();
    return tailerShutdown;
  };
  const shutdownBroker = (): Promise<void> => {
    brokerShutdown ??= broker?.shutdown() ?? Promise.resolve();
    return brokerShutdown;
  };
  return {
    shutdownTailer,
    shutdownBroker,
    onRendererDestroy: () => {
      void shutdownTailer().catch(reportBrokerShutdownFailure);
      void shutdownBroker().catch(reportBrokerShutdownFailure);
    },
  };
}
