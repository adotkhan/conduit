import * as bip39 from "@scure/bip39";
import { wordlist as englishWordlist } from "@scure/bip39/wordlists/english";
import * as SecureStore from "expo-secure-store";
import { z } from "zod";

import {
    Ed25519KeyPair,
    Ed25519KeyPairSchema,
    base64nopadToKeyPair,
    deriveEd25519KeyPair,
    keyPairToBase64nopad,
} from "@/src/common/cryptography";
import { wrapError } from "@/src/common/errors";
import {
    SECURESTORE_ACCOUNT_KEYPAIR_BASE64_KEY,
    SECURESTORE_DEVICE_NONCE_KEY,
    SECURESTORE_INPROXY_KEYPAIR_BASE64_KEY,
    SECURESTORE_MNEMONIC_KEY,
} from "@/src/constants";
import { formatConduitBip32Path } from "@/src/inproxy/utils";

// An "Account" is a collection of key material
const AccountSchema = z.object({
    mnemonic: z.string(),
    accountKey: Ed25519KeyPairSchema,
    deviceNonce: z.number(),
    inproxyKey: Ed25519KeyPairSchema,
});

export type Account = z.infer<typeof AccountSchema>;

/**
 * createOrLoadAccount will first look in SecureStore for saved account keys,
 * and generate new account keys if none are found. Any newly generated material
 * will be persisted by this method.
 */
export async function createOrLoadAccount(): Promise<Account | Error> {
    try {
        // Load mnemonic
        let mnemonic: string;
        const storedMnemonic = await SecureStore.getItemAsync(
            SECURESTORE_MNEMONIC_KEY,
        );
        if (!storedMnemonic) {
            const newMnemonic = bip39.generateMnemonic(englishWordlist);
            await SecureStore.setItemAsync(
                SECURESTORE_MNEMONIC_KEY,
                newMnemonic,
            );
            mnemonic = newMnemonic;
        } else {
            mnemonic = storedMnemonic;
        }

        // Load account key
        let accountKey: Ed25519KeyPair;
        const storedAccountKeyPairBase64nopad = await SecureStore.getItemAsync(
            SECURESTORE_ACCOUNT_KEYPAIR_BASE64_KEY,
        );
        if (!storedAccountKeyPairBase64nopad) {
            const derived = deriveEd25519KeyPair(mnemonic);
            if (derived instanceof Error) {
                throw derived;
            }
            const accountKeyPairBase64nopad = keyPairToBase64nopad(derived);
            if (accountKeyPairBase64nopad instanceof Error) {
                throw derived;
            }
            await SecureStore.setItemAsync(
                SECURESTORE_ACCOUNT_KEYPAIR_BASE64_KEY,
                accountKeyPairBase64nopad,
            );
            accountKey = derived;
        } else {
            const storedAccountKeyPair = base64nopadToKeyPair(
                storedAccountKeyPairBase64nopad,
            );
            if (storedAccountKeyPair instanceof Error) {
                throw storedAccountKeyPair;
            }
            accountKey = storedAccountKeyPair;
        }

        // Load device nonce
        let deviceNonce: number;
        const storedDeviceNonce = await SecureStore.getItemAsync(
            SECURESTORE_DEVICE_NONCE_KEY,
        );
        if (!storedDeviceNonce) {
            const newDeviceNonce = Math.floor(Math.random() * 0x80000000);
            await SecureStore.setItemAsync(
                SECURESTORE_DEVICE_NONCE_KEY,
                newDeviceNonce.toString(),
            );
            deviceNonce = newDeviceNonce;
        } else {
            deviceNonce = parseInt(storedDeviceNonce);
        }

        // Load inproxy key
        let inproxyKey: Ed25519KeyPair;
        const storedConduitKeyPairBase64nopad = await SecureStore.getItemAsync(
            SECURESTORE_INPROXY_KEYPAIR_BASE64_KEY,
        );
        if (!storedConduitKeyPairBase64nopad) {
            const derived = deriveEd25519KeyPair(
                mnemonic,
                formatConduitBip32Path(deviceNonce),
            );
            if (derived instanceof Error) {
                throw derived;
            }
            const inproxyKeyPairBase64nopad = keyPairToBase64nopad(derived);
            if (inproxyKeyPairBase64nopad instanceof Error) {
                throw inproxyKeyPairBase64nopad;
            }
            await SecureStore.setItemAsync(
                SECURESTORE_INPROXY_KEYPAIR_BASE64_KEY,
                inproxyKeyPairBase64nopad,
            );
            inproxyKey = derived;
        } else {
            const storedInproxyKeyPair = base64nopadToKeyPair(
                storedConduitKeyPairBase64nopad,
            );
            if (storedInproxyKeyPair instanceof Error) {
                throw storedInproxyKeyPair;
            }
            inproxyKey = storedInproxyKeyPair;
        }
        return AccountSchema.parse({
            mnemonic: mnemonic,
            accountKey: accountKey,
            deviceNonce: deviceNonce,
            inproxyKey: inproxyKey,
        });
    } catch (error) {
        return wrapError(error, "Error signing in");
    }
}