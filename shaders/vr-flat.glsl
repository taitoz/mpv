//!PARAM vr_projection
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 2
0

//!PARAM vr_stereo_tb
//!TYPE int
//!MINIMUM 0
//!MAXIMUM 2
0

//!PARAM vr_input_fov
//!TYPE float
//!MINIMUM 180
//!MAXIMUM 220
190

//!PARAM vr_hfov
//!TYPE float
//!MINIMUM 30
//!MAXIMUM 140
100

//!PARAM vr_vfov
//!TYPE float
//!MINIMUM 20
//!MAXIMUM 120
60

//!PARAM vr_yaw
//!TYPE float
//!MINIMUM -180
//!MAXIMUM 180
0

//!PARAM vr_pitch
//!TYPE float
//!MINIMUM -85
//!MAXIMUM 85
0

//!HOOK MAIN
//!BIND HOOKED
//!DESC VR to flat perspective (GPU)
//!WIDTH 1920
//!HEIGHT 1080
vec4 hook() {
    const float pi = 3.141592653589793;
    vec2 plane = (HOOKED_pos * 2.0 - 1.0) * vec2(tan(radians(vr_hfov) * 0.5), tan(radians(vr_vfov) * 0.5));
    vec3 ray = normalize(vec3(plane, 1.0));
    float pitch = radians(vr_pitch);
    float yaw = radians(vr_yaw);
    ray.yz = mat2(cos(pitch), -sin(pitch), sin(pitch), cos(pitch)) * ray.yz;
    ray.xz = mat2(cos(yaw), -sin(yaw), sin(yaw), cos(yaw)) * ray.xz;
    vec2 uv;
    if (vr_projection == 2) {
        float radius = length(ray.xy);
        float angle = atan(radius, ray.z);
        uv = vec2(0.5) + (radius > 0.000001 ? ray.xy / radius : vec2(0.0)) * angle / radians(vr_input_fov);
    } else {
        float longitude = atan(ray.x, ray.z);
        float latitude = asin(clamp(ray.y, -1.0, 1.0));
        uv = vec2(0.5 + longitude / (vr_projection == 0 ? pi : 2.0 * pi), 0.5 + latitude / pi);
    }
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return vec4(0.0, 0.0, 0.0, 1.0);
    vec2 eye = vr_stereo_tb == 2 ? vec2(1.0) : (vr_stereo_tb == 1 ? vec2(1.0, 0.5) : vec2(0.5, 1.0));
    vec2 margin = 0.5 / HOOKED_size;
    uv = clamp(uv * eye, margin, eye - margin);
    return HOOKED_tex(uv);
}
