import {
    Blur,
    Canvas,
    Circle,
    ColorMatrix,
    ColorShader,
    Group,
    Image,
    Paint,
    RadialGradient,
    Shadow,
    Text,
    interpolateColors,
    useFont,
    useImage,
    vec,
} from "@shopify/react-native-skia";
import * as Haptics from "expo-haptics";
import React from "react";
import { useTranslation } from "react-i18next";
import { View } from "react-native";
import Animated, {
    Easing,
    cancelAnimation,
    runOnJS,
    useDerivedValue,
    useSharedValue,
    withDelay,
    withRepeat,
    withSequence,
    withSpring,
    withTiming,
} from "react-native-reanimated";
import { z } from "zod";

import { useAnimatedImageValue } from "@/src/animationHooks";
import { timedLog } from "@/src/common/utils";
import { ConduitConnectionLight } from "@/src/components/canvas/ConduitConnectionLight";
import {
    INPROXY_MAX_CLIENTS_MAX,
    PARTICLE_VIDEO_DELAY_MS,
} from "@/src/constants";
import { useInProxyContext } from "@/src/inproxy/context";
import {
    useInProxyCurrentConnectedClients,
    useInProxyStatus,
} from "@/src/inproxy/hooks";
import { fonts, palette, sharedStyles as ss } from "@/src/styles";
import { Gesture, GestureDetector } from "react-native-gesture-handler";

export function ConduitOrbToggle({
    width,
    height,
}: {
    width: number;
    height: number;
}) {
    const { t } = useTranslation();
    const { toggleInProxy } = useInProxyContext();
    const { data: inProxyStatus } = useInProxyStatus();
    const { data: inProxyCurrentConnectedClients } =
        useInProxyCurrentConnectedClients();

    // At the top of the canvas there is a grid of dots around the Psiphon logo,
    // representing the Psiphon Network the InProxy is proxying traffic towards.
    const dotsPng = useImage(require("@/assets/images/dots.png"));
    const psiphonLogoPng = useImage(
        require("@/assets/images/psiphon-logo.png"),
    );
    const psiphonLogoSize = 29;
    // the dots and Psiphon logo will fade in
    const dotsOpacity = useSharedValue(0);
    const psiphonLogoOpacity = useDerivedValue(() => {
        return dotsOpacity.value - 0.2;
    }, [dotsOpacity]);

    // In the center of the canvas is the orb, a button that toggles InProxy.
    // The orb will have an animated gradient depending on InProxyState, flowing
    // between the following colors
    const orbColors = [
        palette.black,
        palette.blueShade3,
        palette.purpleShade3,
        palette.redShade3,
        palette.purpleShade3,
    ];
    // Animate the index of this array of colors, interpolating a gradient
    const orbColorsIndex = useSharedValue(0);
    const orbGradientColors = useDerivedValue(() => {
        return [
            palette.black,
            interpolateColors(orbColorsIndex.value, [0, 1, 2, 3, 4], orbColors),
        ];
    });
    // The "Turn On" text also uses interpolation to appear to fade in by going
    // from transparent to it's final color.
    const orbText = t("TURN_ON_I18N.string");
    const orbTextColors = [palette.transparent, palette.midGrey];
    const orbTextColorIndex = useSharedValue(0);
    const orbTextColor = useDerivedValue(() => {
        return interpolateColors(
            orbTextColorIndex.value,
            [0, 1],
            orbTextColors,
        );
    });
    // The orb will pop into existence at the start, animating from radius 0 up
    const orbRadius = useSharedValue(0);
    const orbDiameter = useDerivedValue(() => orbRadius.value * 2);
    const negativeOrbRadius = useDerivedValue(() => -orbRadius.value);
    const finalOrbRadius = width / 4;
    // Use a transform to center the orb and the lights that flow through it
    const orbCenterY = width / 2 + finalOrbRadius / 2;
    const orbCenteringTransform = [
        {
            translateY: orbCenterY,
        },
        {
            translateX: width / 2,
        },
    ];

    function animateProxyAnnouncing() {
        timedLog("animateProxyAnnouncing()");
        orbColorsIndex.value = withRepeat(
            // only animate through the first 4 colors while announcing
            withTiming(3, {
                duration: 2000,
            }),
            -1,
            true,
        );
        orbTextColorIndex.value = withTiming(0, { duration: 500 });
        dotsOpacity.value = withTiming(1, { duration: 1000 });
    }

    function animateProxyInUse() {
        timedLog("animateProxyInUse()");
        cancelAnimation(orbColorsIndex);
        orbColorsIndex.value = withTiming(4, { duration: 2000 });
        dotsOpacity.value = withTiming(1, { duration: 1000 });
    }

    function animateTurnOffProxy() {
        timedLog("animateTurnOffProxy()");
        cancelAnimation(orbColorsIndex);
        orbColorsIndex.value = withTiming(0, { duration: 500 });
        orbTextColorIndex.value = withTiming(1, { duration: 500 });
        dotsOpacity.value = withTiming(0.2, { duration: 1000 });
    }

    function animateIntro(delay: number) {
        timedLog(`animateIntro(${delay})`);
        orbRadius.value = withDelay(
            delay,
            withSpring(finalOrbRadius, {
                mass: 1.2,
                damping: 10,
                stiffness: 100,
                restDisplacementThreshold: 0.01,
                restSpeedThreshold: 2,
            }),
        );
        dotsOpacity.value = withDelay(
            delay,
            withTiming(0.2, { duration: 1000 }),
        );
        if (delay > 0) {
            // if we're introing with a delay, it means the InProxy is stopped,
            // so we will fade in our button text.
            orbTextColorIndex.value = withDelay(
                delay,
                withTiming(1, { duration: 1000 }),
            );
        }
    }

    // We have 4 animation states that depend on the state of the InProxy:
    const AnimationStateSchema = z.enum([
        // Conduit running but 0 clients connected, the orb will pulse.
        "ProxyAnnouncing",
        // Conduit running with > 0 clients connected, flying lights.
        "ProxyInUse",
        // Conduit stopped, animates values towards the "off" state
        "ProxyIdle",
        // InProxy Status is not yet known, so we don't animate anything yet
        "Unknown",
    ]);
    type AnimationState = z.infer<typeof AnimationStateSchema>;
    const animationState = React.useRef<AnimationState>("Unknown");

    // In addition to the 4 inProxyStatus dependent animation states above, we
    // also have an intro animation gif to play when the app is opened.
    // Use initialStateDetermined ref to track the very first render
    // If InProxy is already RUNNING when the app is opened, the intro animation
    // will be a quick fade in of the UI. If the InProxy is STOPPED when the app
    // is opened, this fade should be delayed until the particle animation video
    // has played.
    // The inProxyStatus will begin as UNKNOWN, and then become RUNNING or
    // STOPPED once the module is hooked up.
    // Use this in initialStateDetermined state variable to coordiate the order
    // of animations: first we want the intro to play, then we want to be hooked
    // up to InProxyStatus changes.
    const particleSwirlPaused = useSharedValue(true);
    const particleSwirlOpacity = useSharedValue(0);
    const particleSwirlGif = useAnimatedImageValue(
        require("@/assets/images/particle-swirl.gif"),
        particleSwirlPaused,
    );
    const [initialStateDetermined, setInitialStateDetermined] =
        React.useState(false);
    React.useEffect(() => {
        if (!initialStateDetermined) {
            if (inProxyStatus === "RUNNING") {
                animateIntro(0);
                setInitialStateDetermined(true);
            } else if (inProxyStatus === "STOPPED") {
                particleSwirlPaused.value = false;
                particleSwirlOpacity.value = 1;
                particleSwirlOpacity.value = withDelay(
                    PARTICLE_VIDEO_DELAY_MS - 200,
                    withTiming(0, { duration: 200 }, () => {
                        particleSwirlPaused.value = true;
                    }),
                );
                animateIntro(PARTICLE_VIDEO_DELAY_MS);
                setInitialStateDetermined(true);
            }
            // implicit do nothing if status is UNKNOWN
        }
    }, [inProxyStatus]);

    React.useEffect(() => {
        if (initialStateDetermined) {
            if (inProxyStatus === "RUNNING") {
                if (inProxyCurrentConnectedClients === 0) {
                    if (animationState.current !== "ProxyAnnouncing") {
                        animateProxyAnnouncing();
                        animationState.current = "ProxyAnnouncing";
                    }
                } else {
                    if (animationState.current !== "ProxyInUse") {
                        animateProxyInUse();
                        animationState.current = "ProxyInUse";
                    }
                }
            } else if (inProxyStatus === "STOPPED") {
                if (
                    animationState.current !== "ProxyIdle" &&
                    animationState.current !== "Unknown"
                ) {
                    animateTurnOffProxy();
                    animationState.current = "ProxyIdle";
                }
            }
            // implicit do nothing if status is UNKNOWN (although we will never
            // get here since initialStateDetermined will be false while proxy
            // status is UNKNOWN)
        }
    }, [inProxyStatus, inProxyCurrentConnectedClients, initialStateDetermined]);

    // This morphLayer creates a neat effect where elements that are close to
    // each other appear to morph together. Any overlapping elements in the
    // Group with this layer applied to it will have the effect applied.
    const morphLayer = React.useMemo(() => {
        return (
            <Paint>
                <Blur blur={5} />
                <ColorMatrix
                    // prettier-ignore
                    matrix={[
                        // R, G, B, A, Bias
                        1, 0, 0, 0, 0,
                        0, 1, 0, 0, 0,
                        0, 0, 1, 0, 0,
                        0, 0, 0, 5, -2,
                    ]}
                />
            </Paint>
        );
    }, []);

    // TODO: switch to the newer Paragraph model
    const font = useFont(fonts.JuraRegular, 20);
    const orbTextXOffset = font ? -font.measureText(orbText).width / 2 : 0;
    const orbTextYOffset = font ? font.measureText(orbText).height / 2 : 0;

    // Orb Gesture
    // Since turning off the proxy will disconnect any connected users, require
    // a long press to turn off. When the user clicks the orb and a toggle would
    // disconnect users, we will show instruction to long press to turn off.
    const longPressInstructionOpacity = useSharedValue(0);

    function animateOrbGiggle() {
        "worklet";
        orbRadius.value = withSequence(
            withTiming(finalOrbRadius * 0.95, {
                duration: 50,
            }),
            withSpring(finalOrbRadius, {
                duration: 1000,
                dampingRatio: 0.1,
                stiffness: 69,
                restDisplacementThreshold: 0.01,
                restSpeedThreshold: 42,
            }),
        );
    }
    const orbGesture = Gesture.Exclusive(
        Gesture.Tap().onEnd(() => {
            if (inProxyCurrentConnectedClients === 0) {
                animateOrbGiggle();
                runOnJS(Haptics.impactAsync)(
                    Haptics.ImpactFeedbackStyle.Medium,
                );
                runOnJS(toggleInProxy)();
            } else {
                animateOrbGiggle();
                longPressInstructionOpacity.value = withSequence(
                    withTiming(1, { duration: 1000 }),
                    withTiming(1, { duration: 3000 }),
                    withTiming(0, { duration: 1000 }),
                );
            }
        }),
        Gesture.LongPress()
            .minDuration(1500)
            .onBegin(() => {
                runOnJS(Haptics.impactAsync)(Haptics.ImpactFeedbackStyle.Soft);
                orbRadius.value = withTiming(finalOrbRadius * 0.85, {
                    duration: 1600,
                    easing: Easing.poly(2),
                });
            })
            .onStart(() => {
                runOnJS(Haptics.impactAsync)(Haptics.ImpactFeedbackStyle.Heavy);
                runOnJS(toggleInProxy)();
                longPressInstructionOpacity.value = withTiming(0, {
                    duration: 500,
                });
            })
            .onFinalize(() => {
                animateOrbGiggle();
            }),
    );

    return (
        <View
            style={{
                width: width,
                height: height,
                backgroundColor: "transparent",
            }}
        >
            <Canvas style={[ss.flex]}>
                <Group>
                    {/* Intro particle swirl animation */}
                    <Image
                        y={finalOrbRadius / 2}
                        image={particleSwirlGif}
                        width={width}
                        height={width}
                        opacity={particleSwirlOpacity}
                    />
                </Group>
                <Group>
                    {/* the red dots at top representing Psiphon Network */}
                    <Image
                        image={dotsPng}
                        x={width / 2 - 128 / 2}
                        y={0}
                        width={128}
                        height={90}
                        fit={"contain"}
                        opacity={dotsOpacity}
                    />
                </Group>
                <Group>
                    {/* The Orb and Lights Scene*/}
                    <Group transform={orbCenteringTransform}>
                        {/* vec(0,0) at the center of the Orb */}
                        <Group layer={morphLayer}>
                            {/* morph layer blurs overlapping elements together */}
                            {/* The Orb */}
                            <Group>
                                <Circle r={orbRadius}>
                                    <Shadow
                                        dx={10}
                                        dy={10}
                                        blur={10}
                                        color={palette.purple}
                                        inner
                                    />
                                    <Shadow
                                        dx={-10}
                                        dy={-10}
                                        blur={10}
                                        color={palette.blue}
                                        inner
                                    />
                                    <RadialGradient
                                        c={vec(0, 0)}
                                        r={finalOrbRadius}
                                        colors={orbGradientColors}
                                    />
                                </Circle>
                                <Circle
                                    r={finalOrbRadius}
                                    style="stroke"
                                    strokeWidth={2}
                                    color={palette.blueTint4}
                                />
                            </Group>
                            {/* 1 flying light per connected client */}
                            {[...Array(INPROXY_MAX_CLIENTS_MAX).keys()].map(
                                (i) => {
                                    return (
                                        <ConduitConnectionLight
                                            key={i}
                                            active={
                                                inProxyCurrentConnectedClients >
                                                i
                                            }
                                            canvasWidth={width}
                                            orbRadius={finalOrbRadius}
                                            orbCenterY={orbCenterY}
                                            psiphonLogoSize={psiphonLogoSize}
                                        />
                                    );
                                },
                            )}
                        </Group>
                        <Group>
                            {/* Turn ON text displayed when Conduit is off */}
                            <Text
                                x={orbTextXOffset}
                                y={orbTextYOffset}
                                text={orbText}
                                font={font}
                            >
                                <ColorShader color={orbTextColor} />
                            </Text>
                        </Group>
                    </Group>
                </Group>
                <Group>
                    {/* the psiphon logo at top z-indexed above orbs */}
                    <Image
                        image={psiphonLogoPng}
                        x={width / 2 - 29 / 2}
                        y={0}
                        width={psiphonLogoSize}
                        height={psiphonLogoSize}
                        fit={"contain"}
                        opacity={psiphonLogoOpacity}
                    />
                </Group>
            </Canvas>
            {/* Pressable overlay over orb to handle gestures */}
            <GestureDetector gesture={orbGesture}>
                <Animated.View
                    style={[
                        ss.absolute,
                        {
                            left: negativeOrbRadius,
                            top: negativeOrbRadius,
                            width: orbDiameter,
                            height: orbDiameter,
                            borderRadius: orbRadius,
                            transform: orbCenteringTransform,
                        },
                    ]}
                />
            </GestureDetector>
            {/* Long press instructions are shown when peers are connected */}
            <Animated.Text
                adjustsFontSizeToFit
                numberOfLines={1}
                style={[
                    ss.whiteText,
                    ss.bodyFont,
                    ss.absolute,
                    {
                        top: orbCenterY + finalOrbRadius + ss.padded.padding,
                        width: "100%",
                        textAlign: "center",
                        opacity: longPressInstructionOpacity,
                    },
                ]}
            >
                {t("HOLD_TO_TURN_OFF_I18N.string")}
            </Animated.Text>
        </View>
    );
}
