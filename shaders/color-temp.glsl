// Copyright (c) 2026 taitoz
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Color temperature adjustment (white point shift, Tanner Helland
// kelvin->RGB approximation, normalized to identity at 6500K).
// Driven by scripts/color-temp.lua via glsl-shader-opts.ctemp.

//!PARAM ctemp
//!TYPE float
//!MINIMUM 1500
//!MAXIMUM 20000
6500

//!HOOK MAIN
//!BIND HOOKED
//!DESC Color temperature (ctemp, kelvin)
vec4 hook() {
    float t = clamp(ctemp, 1000.0, 20000.0) / 100.0;
    float r = t <= 66.0 ? 1.0
        : clamp(329.698727446 * pow(t - 60.0, -0.1332047592) / 255.0, 0.0, 1.0);
    float g = t <= 66.0
        ? clamp((99.4708025861 * log(t) - 161.1195681661) / 255.0, 0.0, 1.0)
        : clamp(288.1221695283 * pow(t - 60.0, -0.0755148492) / 255.0, 0.0, 1.0);
    float b = t >= 66.0 ? 1.0
        : (t <= 19.0 ? 0.0
           : clamp((138.5177312231 * log(t - 10.0) - 305.0447927307) / 255.0, 0.0, 1.0));
    vec3 gain = vec3(r, g, b);

    // reference white at 6500K (t = 65)
    vec3 ref = vec3(1.0,
        clamp((99.4708025861 * log(65.0) - 161.1195681661) / 255.0, 0.0, 1.0),
        clamp((138.5177312231 * log(55.0) - 305.0447927307) / 255.0, 0.0, 1.0));

    vec4 c = HOOKED_texOff(0);
    c.rgb *= gain / ref;
    return c;
}
