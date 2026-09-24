// Host services OpenClaw hands the plugin at registration.
import { createPluginRuntimeStore } from "openclaw/plugin-sdk/runtime-store";
import type { PluginRuntime } from "openclaw/plugin-sdk/runtime-store";

const { setRuntime: setYuiRuntime, getRuntime: getYuiRuntime } = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "yui",
  errorMessage: "Yui runtime not initialized",
});

export { getYuiRuntime, setYuiRuntime };
