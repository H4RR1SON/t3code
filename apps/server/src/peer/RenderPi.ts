import { EnvironmentId, OrchestratorMcpFailure } from "@t3tools/contracts";
import * as Config from "effect/Config";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";

import * as ProcessRunner from "../processRunner.ts";

export const model = "relace/deepseek-ai/DeepSeek-V4.1-Flash-1017";
const Prepared = Schema.fromJsonString(
  Schema.Struct({
    name: Schema.String,
    sandboxId: Schema.String,
    url: Schema.String,
    environmentId: EnvironmentId,
    pairingCode: Schema.String,
  }),
);

export type Prepared = (typeof Prepared)["Type"];
const decodePrepared = Schema.decodeEffect(Prepared);

export const make = Effect.gen(function* () {
  const runner = yield* Effect.serviceOption(ProcessRunner.ProcessRunner);
  const path = yield* Effect.serviceOption(Path.Path);
  const limit = yield* Semaphore.make(8);
  const executable = yield* Config.option(Config.String("T3_RENDER_PI_PROVISIONER")).pipe(
    Effect.orElseSucceed(() => Option.none()),
  );

  const run = Effect.fn("RenderPi.run")(function* (args: ReadonlyArray<string>) {
    if (
      Option.isNone(executable) ||
      Option.isNone(path) ||
      !path.value.isAbsolute(executable.value) ||
      Option.isNone(runner)
    ) {
      return yield* new OrchestratorMcpFailure({
        code: "capability_denied",
        message: "Render Pi provisioning is not configured on this T3 server.",
      });
    }
    const result = yield* runner.value
      .run({ command: executable.value, args, timeout: "5 minutes", maxOutputBytes: 16_384 })
      .pipe(Effect.mapError(() => failure("The Render Pi operator did not finish.")));
    if (result.code !== 0 || result.timedOut) {
      return yield* failure("The Render Pi operator failed. Check the operator's worker state.");
    }
    return result.stdout;
  });

  const prepare = Effect.fn("RenderPi.prepare")(function* (input: {
    readonly requestId: string;
    readonly repository: string;
    readonly branch: string;
    readonly base: string;
  }) {
    const digest = yield* Effect.tryPromise({
      try: () => crypto.subtle.digest("SHA-256", new TextEncoder().encode(input.requestId)),
      catch: () => failure("Could not derive a Render worker name."),
    });
    const hex = Array.from(new Uint8Array(digest, 0, 12), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    const name = `nr-t3-pi-${hex}`;
    return yield* limit.withPermit(
      run(["prepare", name, input.repository, input.branch, input.base]).pipe(
        Effect.flatMap((output) =>
          decodePrepared(output).pipe(
            Effect.mapError(() => failure("The Render Pi operator returned invalid worker data.")),
          ),
        ),
        Effect.filterOrFail(
          (worker) => worker.name === name && isPrivateWorkerUrl(worker.url, name),
          () => failure("The Render Pi operator returned a different worker."),
        ),
      ),
    );
  });

  const retire = (name: string) => limit.withPermit(run(["retire", name])).pipe(Effect.asVoid);
  const adopt = (name: string) => run(["adopt", name]).pipe(Effect.asVoid);
  const reconcile = Option.isSome(executable)
    ? run(["reconcile"]).pipe(Effect.asVoid)
    : Effect.void;
  return { prepare, retire, adopt, reconcile };
});

function isPrivateWorkerUrl(value: string, name: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.origin === value &&
      url.protocol === "https:" &&
      url.hostname.startsWith(`${name}.`) &&
      url.hostname.endsWith(".ts.net")
    );
  } catch {
    return false;
  }
}

function failure(message: string) {
  return new OrchestratorMcpFailure({ code: "orchestration_error", message });
}
