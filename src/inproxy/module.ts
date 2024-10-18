import { NativeModules } from "react-native";

import { InProxyParameters } from "@/src/inproxy/types";

export interface ConduitModuleAPI {
    toggleInProxy: (
        maxClients: number,
        limitUpstreamBytesPerSecond: number,
        limitDownstreamBytesPerSecond: number,
        privateKey: string,
    ) => Promise<void>;
    // Technically the Android implementation can accept a subset of the
    // InProxyParameters, but we will always be sending them all.
    paramsChanged: (params: InProxyParameters) => Promise<void>;
    addListener: (eventName: string) => void;
    removeListeners: (count: number) => void;
    sendFeedback: () => Promise<null | string>;
    logInfo: (tag: string, msg: string) => void;
    logError: (tag: string, msg: string) => void;
    logWarn: (tag: string, msg: string) => void;
}

export const ConduitModule: ConduitModuleAPI = NativeModules.ConduitModule;
