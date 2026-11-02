import extension from "../omp/agterm-status.ts";

type Handler = () => Promise<unknown> | unknown;
const handlers = new Map<string, Handler>();
const calls: string[][] = [];

extension({
	on(event: string, handler: Handler) {
		handlers.set(event, handler);
	},
	async exec(command: string, args: string[]) {
		calls.push([command, ...args]);
		throw new Error("simulated status adapter failure");
	},
} as never);

for (const event of ["agent_start", "turn_start", "agent_end"]) {
	const handler = handlers.get(event);
	if (!handler) throw new Error(`missing ${event} handler`);
	await handler();
}

const args = calls.map(call => call.slice(1));
const expected = [["active", "--blink"], ["active", "--blink"], ["completed"]];
if (JSON.stringify(args) !== JSON.stringify(expected)) {
	throw new Error(`unexpected status calls: ${JSON.stringify(args)}`);
}

console.log("ok: omp extension maps lifecycle events to agterm statuses");
