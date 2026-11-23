// Metal port of the Android renderer's LIT and SKY GLSL programs (render/SceneRenderer.kt).
// Ported: surface types (studs, inlets, welds...), material textures + normal maps, plastic grain,
// sky gradient/clouds, specular/fresnel and distance fog. Not yet ported: shadow maps and the
// ADVANCED procedural materials (textured materials cover most of them).
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 camPos;       // xyz, w: dayFactor
    float4 lightDir;     // xyz effective dir light, w: starCount
    float4 sunColor;     // rgb, w: celestialShown (1 or 0)
    float4 horizon;      // rgb, w: atmoDensity
    float4 zenith;       // rgb, w: atmoHaze
    float4 params;       // x ambient, y exposure, z time, w hasSurfaceTexture
    float4x4 shadowVP;   // sun shadow map projection
    float4 shadowOn;     // x: shadow valid, y: lightCount (0..8), z: atmoGlare, w: atmoOffset
    float4 ambientTint;  // rgb, w: unused
    float4 fogColor;     // rgb, w: fogEnabled (1 or 0)
    float4 fogRange;     // x: fogStart, y: fogEnd, z: trueSunY, w: unused
    float4 trueSunDir;   // xyz: raw sun direction (for sky/moon), w: unused
    float4 lightPos[8];  // xyz world pos, w range
    float4 lightCol[8];  // rgb * brightness, w type (0=point, 1=spot, 2=surface)
    float4 lightDirL[8]; // xyz forward dir, w cos(halfAngle)
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

struct VIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float2 uv [[attribute(2)]]; };

struct VOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float3 localN;
    float3 tangent;
    float3 bitangent;
    float2 uv;
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
    o.uv = in.uv;
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

static float3 evalLocalLights(float3 worldPos, float3 n, constant Frame& f) {
    int count = clamp(int(f.shadowOn.y + 0.5), 0, 8);
    float3 sum = float3(0.0);
    for (int i = 0; i < count; i++) {
        float range = max(f.lightPos[i].w, 0.001);
        float3 toLight = f.lightPos[i].xyz - worldPos;
        float dist = length(toLight);
        if (dist >= range) continue;
        float3 ldir = toLight / max(dist, 1e-4);
        float atten = 1.0 - dist / range;
        atten *= atten;
        float ndl = max(dot(n, ldir), 0.0);
        if (ndl <= 0.0) continue;
        float ltype = f.lightCol[i].w;
        if (ltype > 0.5) {
            // SpotLight (1) / SurfaceLight (2): cone around forward direction.
            float cosA = dot(-ldir, f.lightDirL[i].xyz);
            float cosHalf = f.lightDirL[i].w;
            atten *= smoothstep(cosHalf, min(0.999, cosHalf + 0.14), cosA);
        }
        sum += f.lightCol[i].rgb * (ndl * atten);
    }
    return sum;
}

static float3 applyFog(float3 col, float dist, float3 viewDir, constant Frame& f) {
    float3 fogCol = f.fogColor.rgb;
    float factor = 0.0;
    if (f.fogColor.w > 0.5) {
        factor = clamp((dist - f.fogRange.x) / max(1.0, f.fogRange.y - f.fogRange.x), 0.0, 1.0);
        col = mix(col, fogCol, factor);
    }
    if (f.horizon.w > 0.001) {
        float atmoDist = max(0.0, dist - f.shadowOn.w * 200.0);
        float expFog = (1.0 - exp(-atmoDist * f.horizon.w * 0.0032)) * clamp(0.45 + f.horizon.w * 0.55, 0.0, 0.92);
        float sd = max(dot(viewDir, normalize(f.trueSunDir.xyz)), 0.0);
        float3 atmoTarget = mix(f.horizon.rgb, f.sunColor.rgb * 1.1 + f.horizon.rgb, pow(sd, 6.0) * clamp(f.shadowOn.z * 0.15, 0.0, 0.5));
        col = mix(col, atmoTarget, expFog * (1.0 - factor));
    } else if (f.fogColor.w < 0.5) {
        col = mix(col, f.horizon.rgb, smoothstep(900.0, 5000.0, dist) * 0.7);
    }
    return col;
}

fragment float4 part_fs(VOut in [[stage_in]], bool front [[front_facing]],
                        constant Frame& f [[buffer(1)]],
                        const device PartInstance* insts [[buffer(2)]],
                        texture2d<float> matTex [[texture(0)]],
                        texture2d<float> nrmTex [[texture(1)]],
                        texture2d<float> surfTex [[texture(2)]],
                        depth2d<float> shadowMap [[texture(3)]],
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
    if (p.surfA.w > 0.5) {
        // TrussPart 2-stud open lattice struts and X-bracing.
        float2 cell = fract(uv * 0.5);
        bool border = min(cell.x, 1.0 - cell.x) < 0.14 || min(cell.y, 1.0 - cell.y) < 0.14;
        bool brace = abs(cell.x - cell.y) < 0.11 || abs(cell.x + cell.y - 1.0) < 0.11;
        if (!border && !brace) discard_fragment();
    }
    float sf = yFace ? (in.localN.y > 0.0 ? p.surfA.y : p.surfB.y)
                     : (xFace ? (in.localN.x > 0.0 ? p.surfA.x : p.surfB.x) : (in.localN.z > 0.0 ? p.surfA.z : p.surfB.z));

    float type = mat.x;
    if (type > 18.5 && type < 19.5) {
        // ForceField animated hexagonal/wave rim shield.
        float3 v = normalize(f.camPos.xyz - in.world);
        float rim = pow(1.0 - abs(dot(n, v)), 1.8);
        float wave = 0.5 + 0.5 * sin(uv.x * 2.4 + uv.y * 2.4 - f.params.z * 3.5);
        float hex = fbm2(uv * 1.8 + float2(f.params.z * 0.35, -f.params.z * 0.25));
        float glow = clamp(0.28 + rim * 0.95 + wave * 0.28 + hex * 0.3, 0.2, 1.5);
        float3 ff = (c * glow + float3(0.18, 0.28, 0.45) * rim) * f.params.y;
        float ffAlpha = clamp((0.28 + rim * 0.55 + wave * 0.15) * p.color.a, 0.12, 0.92);
        float dist = length(f.camPos.xyz - in.world);
        ff = applyFog(ff, dist, normalize(in.world - f.camPos.xyz), f);
        return float4(ff, ffAlpha);
    }
    if (p.extra.y > 1.5) {
        // MeshPart / SpecialMesh texture with the mesh's own UVs.
        float4 t = matTex.sample(smp, in.uv);
        c = mix(c, t.rgb, t.a);
        type = 0.0;
    } else if (p.extra.y > 0.5) {
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
        float3 amb = (f.params.x * f.ambientTint.rgb) * mix(float3(0.82), mix(float3(1.0), sky * 1.2, 0.35), 0.5 + 0.5 * n.y);
        float sh = 1.0;
        if (f.shadowOn.x > 0.5 && ndl > 0.0) {
            constexpr sampler cmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
            float4 sp = f.shadowVP * float4(in.world, 1.0);
            float3 q = sp.xyz / sp.w;
            float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
            if (uv.x > 0.001 && uv.x < 0.999 && uv.y > 0.001 && uv.y < 0.999 && q.z < 1.0) {
                float bias = 0.0015 + 0.004 * (1.0 - ndl);
                float2 t = float2(1.0 / 2048.0);
                sh = 0.0;
                for (int dx = -1; dx <= 1; dx++) {
                    for (int dy = -1; dy <= 1; dy++) {
                        sh += shadowMap.sample_compare(cmp, uv + float2(dx, dy) * t, q.z - bias);
                    }
                }
                sh /= 9.0;
                float2 e = min(uv, 1.0 - uv);
                sh = mix(1.0, sh, clamp(min(e.x, e.y) * 12.0, 0.0, 1.0));
            }
        }
        diff *= sh;
        float3 local = evalLocalLights(in.world, n, f);
        col = c * (amb + f.sunColor.rgb * diff + local);
        float3 v = normalize(f.camPos.xyz - in.world);
        float3 h = normalize(light + v);
        float spec = pow(max(dot(n, h), 0.0), 16.0 + mat.w * 80.0) * mat.w;
        col += f.sunColor.rgb * spec * 0.6;
        float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0) * mat.w * 0.25;
        col = mix(col, f.zenith.rgb, fres);
    }
    col *= f.params.y;
    float dist = length(f.camPos.xyz - in.world);
    col = applyFog(col, dist, normalize(in.world - f.camPos.xyz), f);
    return float4(col, p.color.a);
}

// MARK: shadow depth pass

vertex float4 shadow_vs(VIn in [[stage_in]], constant Frame& f [[buffer(1)]],
                        const device PartInstance* insts [[buffer(2)]], uint iid [[instance_id]]) {
    return f.shadowVP * (insts[iid].model * float4(in.pos, 1.0));
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
    if (y < 0.0) col = mix(f.horizon.rgb, f.horizon.rgb * 0.72, clamp(-y * 3.0, 0.0, 1.0));

    float3 sunDir = normalize(f.trueSunDir.xyz);
    float3 moonDir = -sunDir;
    float sd = max(dot(dir, sunDir), 0.0);
    float md = max(dot(dir, moonDir), 0.0);
    if (f.sunColor.w > 0.5) {
        float sunVis = smoothstep(-0.15, 0.08, sunDir.y);
        float sunDisc = smoothstep(0.9985, 0.9994, sd) * 2.6 + pow(sd, 60.0) * 0.24 + pow(sd, 6.0) * 0.10;
        col += f.sunColor.rgb * sunDisc * sunVis;
        float moonVis = smoothstep(-0.15, 0.08, moonDir.y);
        float moonDisc = smoothstep(0.9991, 0.9996, md) * 1.4 + pow(md, 90.0) * 0.22;
        col += float3(0.75, 0.84, 1.0) * moonDisc * moonVis;
    }

    float nightMask = (1.0 - f.camPos.w) * smoothstep(0.02, 0.25, y);
    if (nightMask > 0.01 && f.lightDir.w > 1.0) {
        float2 starUV = dir.xz / (abs(y) + 0.35) * 95.0;
        float2 cell = floor(starUV);
        float2 fr = fract(starUV) - 0.5;
        float r = hash2(cell);
        float thresh = clamp(f.lightDir.w / 3000.0, 0.0, 2.0) * 0.045;
        if (r > (1.0 - thresh)) {
            float tw = 0.7 + 0.3 * sin(f.params.z * 2.2 + r * 62.8);
            float st = smoothstep(0.18, 0.02, length(fr)) * tw * nightMask;
            col += float3(0.88, 0.93, 1.0) * st;
        }
    }

    if (y > 0.0) {
        float t = f.params.z;
        float2 uv = dir.xz / (y + 0.12) * 1.6 + float2(t * 0.004, t * 0.002);
        float v = 0.0, amp = 0.5;
        for (int i = 0; i < 5; i++) { v += noise2(uv) * amp; uv = uv * 2.02 + 3.7; amp *= 0.5; }
        float cl = smoothstep(0.52, 0.78, v);
        float fade = smoothstep(0.0, 0.25, y);
        float3 cloudCol = mix(float3(0.14, 0.18, 0.28), float3(1.0), f.camPos.w) * (0.85 + 0.15 * sd);
        col = mix(col, cloudCol, cl * fade * 0.75);
    }
    if (f.horizon.w > 0.001) {
        float hz = pow(1.0 - clamp(abs(y), 0.0, 1.0), 3.0) * clamp(f.horizon.w * 0.9 + f.zenith.w * 0.08, 0.0, 0.85);
        col = mix(col, f.horizon.rgb, hz);
        col += f.horizon.rgb * pow(sd, 4.0) * clamp(f.shadowOn.z * 0.1, 0.0, 0.45) * f.camPos.w;
    }
    return float4(col * clamp(f.params.y, 0.3, 2.5), 1.0);
}

struct SkyboxUniforms { float4x4 rot; };
struct SkyboxOut { float4 position [[position]]; float2 uv; };

vertex SkyboxOut skybox_vs(VIn in [[stage_in]], constant Frame& f [[buffer(1)]], constant SkyboxUniforms& u [[buffer(2)]]) {
    float3 dir = (u.rot * float4(in.pos, 0.0)).xyz;
    float4 p = f.viewProj * float4(f.camPos.xyz + dir * 400.0, 1.0);
    SkyboxOut o;
    o.position = float4(p.xy, p.w * 0.9999, p.w);
    o.uv = in.uv;
    return o;
}

fragment float4 skybox_fs(SkyboxOut in [[stage_in]], constant Frame& f [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    float dayTint = f.camPos.w * 0.65 + 0.35;
    float3 c = tex.sample(smp, in.uv).rgb * dayTint * clamp(f.params.y, 0.3, 2.5);
    return float4(c, 1.0);
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

// MARK: decals & textures on part faces (DECAL_VS/DECAL_FS in the Android renderer)

struct DecalInstance { float4x4 model; float4 tint; float4 uv; float4 normal; };

struct DOut { float4 position [[position]]; float2 uv; float4 tint; float3 normal; float3 world; };

vertex DOut decal_vs(VIn in [[stage_in]], constant Frame& f [[buffer(1)]],
                     const device DecalInstance* insts [[buffer(2)]], uint iid [[instance_id]]) {
    DecalInstance d = insts[iid];
    float4 w = d.model * float4(in.pos, 1.0);
    DOut o;
    o.position = f.viewProj * w;
    o.uv = in.uv * d.uv.xy + d.uv.zw;
    o.tint = d.tint;
    o.normal = d.normal.xyz;
    o.world = w.xyz;
    return o;
}

fragment float4 decal_fs(DOut in [[stage_in]], constant Frame& f [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    float4 t = tex.sample(smp, in.uv);
    float3 n = normalize(in.normal);
    float diff = max(dot(n, f.lightDir.xyz), 0.0);
    float3 amb = f.params.x * f.ambientTint.rgb;
    float3 local = evalLocalLights(in.world, n, f);
    float3 col = t.rgb * in.tint.rgb * (amb + f.sunColor.rgb * diff + local) * f.params.y;
    float dist = length(f.camPos.xyz - in.world);
    col = applyFog(col, dist, normalize(in.world - f.camPos.xyz), f);
    return float4(col, t.a * in.tint.a);
}

// MARK: terrain (render/TerrainView.kt): smooth voxel mesh with per-vertex material colour,
// lit like parts (sun, sky ambient, shadow map, fog), and a translucent water surface.

struct TIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float4 col [[attribute(2)]]; };
struct TOut { float4 position [[position]]; float3 world; float3 normal; float4 color; };

vertex TOut terrain_vs(TIn in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    TOut o;
    o.position = f.viewProj * float4(in.pos, 1.0);
    o.world = in.pos;
    o.normal = in.nrm;
    o.color = in.col;
    return o;
}

static float terrainShadow(constant Frame& f, float3 world, float ndl, depth2d<float> shadowMap) {
    if (f.shadowOn.x < 0.5 || ndl <= 0.0) return 1.0;
    constexpr sampler cmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float4 sp = f.shadowVP * float4(world, 1.0);
    float3 q = sp.xyz / sp.w;
    float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    if (uv.x <= 0.001 || uv.x >= 0.999 || uv.y <= 0.001 || uv.y >= 0.999 || q.z >= 1.0) return 1.0;
    float bias = 0.002 + 0.005 * (1.0 - ndl);
    float2 t = float2(1.0 / 2048.0);
    float sh = 0.0;
    for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) sh += shadowMap.sample_compare(cmp, uv + float2(dx, dy) * t, q.z - bias);
    sh /= 9.0;
    float2 e = min(uv, 1.0 - uv);
    return mix(1.0, sh, clamp(min(e.x, e.y) * 12.0, 0.0, 1.0));
}

fragment float4 terrain_fs(TOut in [[stage_in]], bool front [[front_facing]], constant Frame& f [[buffer(1)]],
                           depth2d<float> shadowMap [[texture(3)]]) {
    float3 n = normalize(in.normal);
    float3 c = in.color.rgb;
    // Gentle world-space grain so large areas don't look flat.
    c *= 1.0 + (fbm2(in.world.xz * 0.35) - 0.5) * 0.16;
    float3 light = f.lightDir.xyz;
    float ndl = dot(n, light);
    float diff = max(ndl, 0.0) * terrainShadow(f, in.world, ndl, shadowMap);
    float3 sky = mix(f.horizon.rgb, f.zenith.rgb, 0.5);
    float3 amb = (f.params.x * f.ambientTint.rgb) * mix(float3(0.82), mix(float3(1.0), sky * 1.2, 0.35), 0.5 + 0.5 * n.y);
    float3 local = evalLocalLights(in.world, n, f);
    float3 col = c * (amb + f.sunColor.rgb * diff + local);
    col *= f.params.y;
    float dist = length(f.camPos.xyz - in.world);
    col = applyFog(col, dist, normalize(in.world - f.camPos.xyz), f);
    return float4(col, 1.0);
}

struct WIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; };
struct WOut { float4 position [[position]]; float3 world; float3 normal; };

vertex WOut water_vs(WIn in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    WOut o;
    float3 p = in.pos;
    // Small waves on upward-facing water.
    if (in.nrm.y > 0.5) p.y += sin(p.x * 0.15 + f.params.z * 1.4) * cos(p.z * 0.13 + f.params.z * 1.1) * 0.25;
    o.position = f.viewProj * float4(p, 1.0);
    o.world = p;
    o.normal = in.nrm;
    return o;
}

// waterColor.rgb + transparency in .a (Terrain.WaterColor / WaterTransparency).
fragment float4 water_fs(WOut in [[stage_in]], constant Frame& f [[buffer(1)]], constant float4& water [[buffer(3)]]) {
    float3 n = normalize(in.normal);
    float3 v = normalize(f.camPos.xyz - in.world);
    if (dot(n, v) < 0.0) n = -n;
    float t = f.params.z;
    float2 rip = float2(noise2(in.world.xz * 0.2 + t * 0.3), noise2(in.world.xz * 0.23 - t * 0.25)) - 0.5;
    n = normalize(n + float3(rip.x, 0.0, rip.y) * 0.35);
    float3 light = f.lightDir.xyz;
    float diff = max(dot(n, light), 0.0);
    float3 amb = f.params.x * f.ambientTint.rgb;
    float3 base = water.rgb * (amb + f.sunColor.rgb * diff * 0.6);
    float fres = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    float3 col = mix(base, f.zenith.rgb * 1.1, fres * 0.6);
    float3 h = normalize(light + v);
    col += f.sunColor.rgb * pow(max(dot(n, h), 0.0), 80.0) * 0.8;
    col *= f.params.y;
    float dist = length(f.camPos.xyz - in.world);
    col = applyFog(col, dist, normalize(in.world - f.camPos.xyz), f);
    float alpha = clamp(1.0 - water.a * 0.75 + fres * 0.3, 0.25, 0.95);
    return float4(col, alpha);
}

vertex float4 terrain_shadow_vs(TIn in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    return f.shadowVP * float4(in.pos, 1.0);
}

// MARK: post-processing (render/PostFx.kt: Bloom, Blur, SunRays, ColorCorrection)

struct PostFxUniforms {
    float4 params; // x: threshold (bright) / bloom (comp), y: blur (comp), zw: blur dir
    float4 cc;     // xyz: brightness, contrast, saturation
    float4 tint;   // rgb: tint
    float4 rays;   // xy: sunUV, z: intensity, w: spread
};

struct PostOut { float4 position [[position]]; float2 uv; };

vertex PostOut postfx_vs(uint vid [[vertex_id]]) {
    float2 pts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    PostOut o;
    o.position = float4(pts[vid], 0.0, 1.0);
    o.uv = float2(pts[vid].x * 0.5 + 0.5, 0.5 - pts[vid].y * 0.5);
    return o;
}

fragment float4 postfx_bright_fs(PostOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]],
                                 constant PostFxUniforms& u [[buffer(0)]]) {
    float3 c = tex.sample(smp, in.uv).rgb;
    float thresh = u.params.x;
    if (thresh < 0.0) return float4(c, 1.0);
    float l = mix(dot(c, float3(0.299, 0.587, 0.114)), max(c.r, max(c.g, c.b)), 0.5);
    float k = smoothstep(thresh, thresh + 0.25, l);
    return float4(c * k, 1.0);
}

fragment float4 postfx_blur_fs(PostOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]],
                               constant PostFxUniforms& u [[buffer(0)]]) {
    float2 dir = u.params.zw;
    float3 c = tex.sample(smp, in.uv).rgb * 0.227;
    c += tex.sample(smp, in.uv + dir * 1.385).rgb * 0.316;
    c += tex.sample(smp, in.uv - dir * 1.385).rgb * 0.316;
    c += tex.sample(smp, in.uv + dir * 3.231).rgb * 0.070;
    c += tex.sample(smp, in.uv - dir * 3.231).rgb * 0.070;
    return float4(c, 1.0);
}

fragment float4 postfx_comp_fs(PostOut in [[stage_in]],
                               texture2d<float> sceneTex [[texture(0)]],
                               texture2d<float> brightTex [[texture(1)]],
                               sampler smp [[sampler(0)]],
                               constant PostFxUniforms& u [[buffer(0)]]) {
    float3 c = sceneTex.sample(smp, in.uv).rgb;
    float3 soft = brightTex.sample(smp, in.uv).rgb;
    float bloom = u.params.x;
    float blur = u.params.y;
    if (blur > 0.0) c = mix(c, soft, blur);
    else if (bloom > 0.0) c = 1.0 - (1.0 - c) * (1.0 - clamp(soft * bloom * 0.6, 0.0, 1.0));
    if (u.rays.z > 0.001) {
        float2 d = (u.rays.xy - in.uv) * (u.rays.w / 16.0);
        float2 p = in.uv;
        float decay = 1.0;
        float3 acc = float3(0.0);
        for (int i = 0; i < 16; i++) {
            p += d;
            acc += brightTex.sample(smp, p).rgb * decay;
            decay *= 0.9;
        }
        c += acc * (u.rays.z / 16.0);
    }
    c += u.cc.x;
    c = (c - 0.5) * (1.0 + u.cc.y) + 0.5;
    float l = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l), c, 1.0 + u.cc.z);
    c *= u.tint.rgb;
    return float4(clamp(c, 0.0, 1.0), 1.0);
}
