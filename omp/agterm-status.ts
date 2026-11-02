import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { fileURLToPath } from "node:url";

const statusScript = fileURLToPath(new URL("./agterm-status.sh", import.meta.url));

export default function (pi: ExtensionAPI) {
	const setStatus = async (...args: string[]) => {
		try {
			await pi.exec(statusScript, args);
		} catch {
			// Статус agterm не должен прерывать работу агента.
		}
	};

	pi.on("agent_start", () => setStatus("active", "--blink"));
	pi.on("turn_start", () => setStatus("active", "--blink"));
	pi.on("agent_end", () => setStatus("completed"));
}
