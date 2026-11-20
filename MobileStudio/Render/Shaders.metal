// Metal port of the Android renderer's LIT and SKY GLSL programs (render/SceneRenderer.kt).
// Ported: surface types (studs, inlets, welds...), material textures + normal maps, plastic grain,
// sky gradient/clouds, specular/fresnel and distance fog. Not yet ported: shadow maps and the
// ADVANCED procedural materials (textured materials cover most of them).
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 camPos;      // xyz
    float4 lightDir;    // xyz, towards the sun
    float4 sunColor;    // rgb
    float4 horizon;     // rgb
    float4 zenith;      // rgb
    float4 params;      // x ambient, y exposure, z time, w hasSurfaceTexture
};

struct PartInstance {
    float4x4 model;     // includes size scale
    float4x4 rotation;  // rotation only (normals)
    float4 color;       // rgb + alpha
    float4 size;        // xyz studs
    float4 surfA;       // +X(Right) +Y(Top) +Z(Back) surface types
    float4 surfB;       // -X(Left) -Y(Bottom) -Z(Front)
    float4 mat;         // x type, y amount, z scale, w specular
    float4 extra;       // x emissive, y textured, z tex scale, w has normal map
};

struct VIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; };

struct VOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float3 localN;
    float3 tangent;
    float3 bitangent;
    uint inst [[flat]];
};

vertex VOut part_vs(VIn in [[stage_in]], constant Frame& f [[buffer(1)]],
                    const device PartInstance* insts [[buffer(2)]], uint iid [[instance_id]]) {
    PartInstance p = insts[iid];
    float4 w = p.model * float4(in.pos, 1.0);
    VOut o;
    o.position = f.viewProj * w;
    o.world = w.xyz;
    o.normal = (p.rotation * float4(in.nrm, 0.0)).xyz;
    o.local = in.pos;
    o.localN = in.nrm;
    float3 an = abs(in.nrm);
    bool yF = an.y > an.x && an.y > an.z; bool xF = !yF && an.x > an.z;
    o.tangent = (p.rotation * float4(yF ? float3(1, 0, 0) : (xF ? float3(0, 0, 1) : float3(1, 0, 0)), 0)).xyz;
    o.bitangent = (p.rotation * float4(yF ? float3(0, 0, 1) : float3(0, 1, 0), 0)).xyz;
    o.inst = iid;
    return o;
}

static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float noise2(float2 p) {
    float2 i = floor(p); float2 fr = fract(p); fr = fr * fr * (3.0 - 2.0 * fr);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), fr.x), mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), fr.x), fr.y);
}
static float fbm2(float2 p) { return noise2(p) * 0.5 + noise2(p * 2.03 + 7.1) * 0.3 + noise2(p * 4.1 + 3.3) * 0.2; }

static float studShade(float2 fr, float R) {
    float2 L = float2(-0.62, 0.78);
    float r = length(fr);
    float inside = smoothstep(R + 0.012, R - 0.012, r);
    float rim = smoothstep(R - 0.09, R, r) * inside;
    float side = dot(fr / max(r, 0.001), L);
    float shadow = smoothstep(R + 0.1, R, length(fr + L * 0.05)) * (1.0 - inside);
    return 1.0 + inside * 0.05 + rim * side * 0.22 - shadow * 0.2;
}

static float3 surface(float3 c, float s, float2 sp, float2 fsz, bool hasTex, texture2d<float> surfTex, sampler smp) {
    if (s < 0.5 || s > 9.5) return c;
    if (hasTex && s < 5.5) {
        float2 st = float2(sp.x * 0.5, -sp.y * 0.125);
        float3 t = surfTex.sample(smp, st).rgb;
        float k;
        if (s < 2.5) k = t.g;
        else if (s < 3.5) k = t.r;
        else if (s < 4.5) k = t.b;
        else { float2 cell = floor(fract(st) * float2(2.0, 8.0)); k = fmod(cell.x + cell.y, 2.0) < 0.5 ? t.r : t.b; }
        return c * (k * 2.0);
    }
    float2 fr = fract(sp) - 0.5; float r = length(fr);
    if (s > 2.5 && s < 3.5) {
        c *= studShade(fr, 0.29);
    } else if (s > 3.5 && s < 4.5) {
        float2 L = float2(-0.62, 0.78);
        float inside = smoothstep(0.302, 0.278, r);
        float rim = smoothstep(0.2, 0.29, r) * inside;
        c *= 1.0 - inside * 0.16 - rim * dot(fr / max(r, 0.001), L) * 0.2 + smoothstep(0.36, 0.3, r) * (1.0 - inside) * 0.05;
    } else if (s > 4.5 && s < 5.5) {
        c *= studShade(fr, 0.29) * (1.0 - smoothstep(0.14, 0.12, r) * 0.18);
    } else if (s > 1.5 && s < 2.5) {
        float l = fract((sp.x + sp.y) * 1.25);
        c *= mix(1.0, 0.84, smoothstep(0.82, 0.88, l) * smoothstep(1.0, 0.94, l));
    } else if (s > 0.5 && s < 1.5) {
        float2 g = abs(fract(sp * 2.0) - 0.5);
        float cr = max(step(g.x, 0.05) * step(g.y, 0.22), step(g.y, 0.05) * step(g.x, 0.22));
        c *= 1.0 - 0.14 * cr;
    } else {
        float rr = length(sp - fsz * 0.5);
        float3 yellow = float3(0.96, 0.8, 0.16);
        if (s > 6.5) {
            if (rr < 0.75) c = mix(c, float3(0.45, 0.45, 0.47), smoothstep(0.75, 0.7, rr));
            if (s > 7.5 && rr < 0.75 && rr > 0.5) {
                float a = atan2(sp.y - fsz.y * 0.5, sp.x - fsz.x * 0.5);
                c *= 0.75 + 0.25 * step(0.5, fract(a * 1.273));
            }
        }
        if (rr < 0.45) c = mix(c, yellow, smoothstep(0.45, 0.4, rr));
    }
    return c;
}

fragment float4 part_fs(VOut in [[stage_in]], bool front [[front_facing]],
                        constant Frame& f [[buffer(1)]],
                        const device PartInstance* insts [[buffer(2)]],
                        texture2d<float> matTex [[texture(0)]],
                        texture2d<float> nrmTex [[texture(1)]],
                        texture2d<float> surfTex [[texture(2)]],
                        sampler smp [[sampler(0)]]) {
    PartInstance p = insts[in.inst];
    float3 n = normalize(in.normal);
    if (!front) n = -n;
    float3 c = p.color.rgb;
    float4 mat = p.mat;

    float3 size = p.size.xyz;
    float3 a = abs(in.localN);
    float3 lp = in.local * size + size * 0.5;
    bool yFace = a.y > a.x && a.y > a.z; bool xFace = !yFace && a.x > a.z;
    float2 uv = yFace ? lp.xz : (xFace ? lp.zy : lp.xy);
    float2 fsz = yFace ? size.xz : (xFace ? size.zy : size.xy);
    float sf = yFace ? (in.localN.y > 0.0 ? p.surfA.y : p.surfB.y)
                     : (xFace ? (in.localN.x > 0.0 ? p.surfA.x : p.surfB.x) : (in.localN.z > 0.0 ? p.surfA.z : p.surfB.z));

    float type = mat.x;
    if (p.extra.y > 0.5) {
        float2 tuv = float2(uv.x, -uv.y) * p.extra.z;
        c *= matTex.sample(smp, tuv).rgb * 1.08;
        type = 0.0;
    }
    if (p.extra.w > 0.5) {
        float2 tuv = float2(uv.x, -uv.y) * p.extra.z;
        float3 tn = nrmTex.sample(smp, tuv).xyz * 2.0 - 1.0;
        n = normalize(normalize(in.tangent) * tn.x + normalize(in.bitangent) * tn.y + n * max(tn.z, 0.25));
    }
    if (type > 0.5) {
        // Lean fallback for untextured materials: grain noise scaled by the material's amount.
        c *= 1.0 + (fbm2(uv * mat.z) - 0.5) * mat.y * 2.0;
    } else {
        c *= 1.0 + (noise2(uv * 2.2) - 0.5) * mat.y * 2.0;
    }
    c = surface(c, sf, uv, fsz, f.params.w > 0.5, surfTex, smp);

    float3 col;
    float3 light = f.lightDir.xyz;
    if (p.extra.x > 0.5) {
        col = c * 1.15 + float3(0.06);
    } else {
        float ndl = dot(n, light);
        float diff = max(ndl, 0.0);
        float3 sky = mix(f.horizon.rgb, f.zenith.rgb, 0.5);
        float3 amb = f.params.x * mix(float3(0.82), mix(float3(1.0), sky * 1.2, 0.35), 0.5 + 0.5 * n.y);
        col = c * (amb + f.sunColor.rgb * diff);
        float3 v = normalize(f.camPos.xyz - in.world);
        float3 h = normalize(light + v);
        float spec = pow(max(dot(n, h), 0.0), 16.0 + mat.w * 80.0) * mat.w;
        col += f.sunColor.rgb * spec * 0.6;
        float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0) * mat.w * 0.25;
        col = mix(col, f.zenith.rgb, fres);
    }
    col *= f.params.y;
    float dist = length(f.camPos.xyz - in.world);
    float fog = smoothstep(900.0, 5000.0, dist) * 0.7;
    col = mix(col, f.horizon.rgb, fog);
    return float4(col, p.color.a);
}

// MARK: sky

struct SkyOut { float4 position [[position]]; float2 ndc; };

vertex SkyOut sky_vs(uint vid [[vertex_id]]) {
    float2 pts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyOut o;
    o.ndc = pts[vid];
    o.position = float4(pts[vid], 0.9999, 1.0);
    return o;
}

fragment float4 sky_fs(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    float4 far = f.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 dir = normalize(far.xyz / far.w - f.camPos.xyz);
    float y = dir.y;
    float3 col = mix(f.horizon.rgb, f.zenith.rgb, pow(clamp(y, 0.0, 1.0), 0.55));
    if (y < 0.0) col = mix(f.horizon.rgb, f.horizon.rgb * 0.8, clamp(-y * 3.0, 0.0, 1.0));
    float sd = max(dot(dir, f.lightDir.xyz), 0.0);
    col += f.sunColor.rgb * (pow(sd, 900.0) * 3.0 + pow(sd, 60.0) * 0.18 + pow(sd, 6.0) * 0.08);
    if (y > 0.0) {
        float t = f.params.z;
        float2 uv = dir.xz / (y + 0.12) * 1.6 + float2(t * 0.004, t * 0.002);
        float v = 0.0, amp = 0.5;
        for (int i = 0; i < 5; i++) { v += noise2(uv) * amp; uv = uv * 2.02 + 3.7; amp *= 0.5; }
        float cl = smoothstep(0.52, 0.78, v);
        float fade = smoothstep(0.0, 0.25, y);
        col = mix(col, float3(1.0) * (0.85 + 0.15 * sd), cl * fade * 0.85);
    }
    return float4(col, 1.0);
}

// MARK: overlay (selection boxes, tool handles): flat colour, optional simple shading

struct OverlayInstance { float4x4 model; float4 color; };

struct OOut { float4 position [[position]]; float4 color; float shade; };

vertex OOut overlay_vs(VIn in [[stage_in]], constant Frame& f [[buffer(1)]],
                       const device OverlayInstance* insts [[buffer(2)]], uint iid [[instance_id]]) {
    OverlayInstance p = insts[iid];
    OOut o;
    o.position = f.viewProj * (p.model * float4(in.pos, 1.0));
    float3 n = normalize((p.model * float4(in.nrm, 0.0)).xyz);
    o.shade = length(in.nrm) < 0.01 ? 1.0 : 0.75 + 0.25 * max(dot(n, f.lightDir.xyz), 0.0);
    o.color = p.color;
    return o;
}

fragment float4 overlay_fs(OOut in [[stage_in]]) {
    return float4(in.color.rgb * in.shade, in.color.a);
}
