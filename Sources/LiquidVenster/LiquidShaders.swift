/// Metal source, compiled at runtime (no Xcode / metal toolchain needed).
///
/// Pass 1 (`splat*`): every drop is drawn as a soft, velocity-stretched blob into a
/// half-float "fluid" texture: (uv.x * w, uv.y * w, w, age * w). Summing the weights
/// gives a metaball field; dividing by it gives the average window-uv and age.
///
/// Pass 2 (`composite*`): treats the field as a height map of water and shades it
/// physically inspired: refraction with a little dispersion, colour absorption that
/// grows with depth (Beer–Lambert), Fresnel reflection, sharp sun glints, caustics,
/// a darker meniscus edge and a soft shadow. On top: the part of the window that is
/// still solid, which already looks wet and turns glassy just before it melts.
enum LiquidShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Particle { float4 a; float4 b; float4 c; float4 d; };

    struct Uniforms {
        float4 view;    // viewW, viewH (points), scaleX, scaleY
        float4 time;    // t, total, dissolveTime, rippleStrength
        float4 win;     // x, y, w, h (points, top-left origin)
        float4 melt;    // meltStart, meltSpan, jitter, sagAccel
        float4 points;  // target.xy, rippleOrigin.xy
        float4 misc;    // threshold, opaque, cornerRadius, fadeWindow
        float4 dock;    // firstArrival, lastArrival, normal.xy
        float4 fluid;   // texel.xy, 1 / resting field
        float4 water;   // colour rgb, strength
        float4 effect;  // 0 = water, 1 = steam
    };

    constant float kPi = 3.14159265;
    constant float kEase = 1.55;

    // ---- shared with LiquidTimeline (Swift) -------------------------------------------
    static float dripNoise(float x) {
        float a = pow(max(0.0, 0.5 + 0.5 * sin(x * 23.0 + 1.3)), 8.0);
        float b = 0.7 * pow(max(0.0, 0.5 + 0.5 * sin(x * 37.0 + 4.1)), 10.0);
        float c = 0.25 * sin(x * 6.0 + 2.0);
        return (a + b + c - 0.85) / 1.1;
    }
    static float steamOrder(float u, float v) {
        float edge = min(min(u, 1.0 - u), min(v, 1.0 - v)) * 2.0;
        float n = 0.5 + 0.22 * sin(u * 11.0 + v * 7.3 + 1.7) + 0.16 * sin(u * 23.1 - v * 17.9 + 0.4)
                + 0.12 * sin(u * 41.7 + v * 37.3 + 2.9);
        return clamp(0.55 * n + 0.45 * edge, 0.0, 1.0);
    }
    static float releaseTime(float2 q, constant Uniforms& u) {
        if (u.effect.x > 0.5) { return u.melt.x + u.melt.y * steamOrder(q.x, q.y); }
        return u.melt.x + (1.0 - q.y) * u.melt.y + dripNoise(q.x) * u.melt.z;
    }
    static float sagAt(float t, constant Uniforms& u) {
        float d = max(0.0, t - u.melt.x);
        return 0.5 * u.melt.w * d * d;
    }
    // -------------------------------------------------------------------------------------

    static float2 bezierPoint(float2 p0, float2 c1, float2 c2, float2 p3, float s) {
        float i = 1.0 - s;
        return i * i * i * p0 + 3.0 * i * i * s * c1 + 3.0 * i * s * s * c2 + s * s * s * p3;
    }
    static float2 bezierTangent(float2 p0, float2 c1, float2 c2, float2 p3, float s) {
        float i = 1.0 - s;
        return 3.0 * i * i * (c1 - p0) + 6.0 * i * s * (c2 - c1) + 3.0 * s * s * (p3 - c2);
    }

    struct SplatOut {
        float4 position [[position]];
        float2 local;
        float2 uv;
        float age;
        float strength;
        float soft;
    };

    vertex SplatOut splatVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device Particle* particles [[buffer(0)]],
                                constant Uniforms& u [[buffer(1)]])
    {
        SplatOut o;
        Particle p = particles[iid];
        float t = u.time.x;
        float release = p.c.z;
        float travel = max(p.c.w, 0.05);
        float fade = max(u.misc.w, 0.001);
        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        o.local = corner;
        o.uv = p.c.xy;
        o.age = 0.0;
        o.strength = 0.0;
        o.soft = 0.0;

        float tau = t - release;
        if (t < release - fade || tau >= travel) {
            // Not active: collapse the quad far outside the viewport so it is culled.
            o.position = float4(-4.0, -4.0, 0.0, 1.0);
            return o;
        }
        float tc = max(tau, 0.0);
        float2 p0 = p.a.xy;
        float2 drain = p.a.zw;
        float2 pos;
        float2 vel;
        float absorb = 0.0;
        float grow = 1.0;
        float fadeOut = 1.0;
        bool steam = p.d.w > 1.5;

        if (steam) {
            // Steam: buoyant puff that rises faster and faster, drifts, swirls, grows and fades.
            float life = clamp(tau / travel, 0.0, 1.0);
            float driftX = p.a.z;
            float rise = p.a.w;
            float buoyancy = p.b.x;
            float turbulence = p.b.y;
            float growth = p.b.z;
            float ph = p.d.y;
            pos = p0 + float2(driftX * tc, -(rise * tc + 0.5 * buoyancy * tc * tc));
            // Coherent swirl: a slowly moving flow field shared by neighbouring puffs, so
            // the steam forms wisps instead of loose blobs.
            float swirl = min(tc * 2.0, 1.0) * turbulence * 1.5;
            pos += float2(sin(pos.y * 0.035 + t * 1.7 + ph) + 0.5 * sin(pos.y * 0.071 - t * 2.3 + ph * 2.0),
                          0.5 * cos(pos.x * 0.03 - t * 1.3 + ph * 0.5)) * swirl;
            vel = float2(driftX, -(rise + buoyancy * tc));
            grow = 1.0 + (growth - 1.0) * life;
            fadeOut = 1.0 - smoothstep(0.25, 1.0, life);
            o.soft = 1.0;
        } else if (p.d.w > 0.5) {
            // Gravity: free fall, splash on the Dock, thin film running into the icon.
            float vx0 = p.b.x;
            float g = max(p.b.y, 1.0);
            float floorY = p.b.z;
            float flowT = max(p.b.w, 0.05);
            float tLand = sqrt(2.0 * max(floorY - p0.y, 0.0) / g);
            if (tc < tLand) {
                float sway = sin(p.d.y * 40.0 + t * 9.0) * 1.5 * min(tc * 4.0, 1.0);
                pos = float2(p0.x + vx0 * tc + sway, p0.y + 0.5 * g * tc * tc);
                vel = float2(vx0, g * tc);
                absorb = 0.0;
            } else {
                float t2 = tc - tLand;
                float s = clamp(t2 / flowT, 0.0, 1.0);
                float xLand = p0.x + vx0 * tLand;
                float e = s * s * (3.0 - 2.0 * s);
                pos.x = mix(xLand, drain.x, e);
                pos.y = mix(floorY, drain.y, smoothstep(0.72, 1.0, s));
                // Some drops bounce up and sideways right after hitting the Dock.
                float impact = clamp(g * tLand / 2600.0, 0.0, 1.0);
                float b = clamp(t2 / 0.2, 0.0, 1.0);
                float side = sin(p.d.y * 91.7);
                pos.y -= p.d.z * impact * sin(kPi * b);
                pos.x += side * p.d.z * impact * 1.3 * b * (1.0 - s);
                vel = float2((drain.x - xLand) * 6.0 * s * (1.0 - s) / flowT, 0.0);
                absorb = smoothstep(0.78, 1.0, s);
            }
        } else {
            // Curve (Dock on the side).
            float ltc = clamp(tau / travel, 0.0, 1.0);
            float s = ltc > 0.0 ? pow(ltc, kEase) : 0.0;
            float2 c1 = p.b.xy;
            float2 c2 = p.b.zw;
            pos = bezierPoint(p0, c1, c2, drain, s);
            float dsdu = kEase * pow(max(ltc, 1e-3), kEase - 1.0);
            vel = bezierTangent(p0, c1, c2, drain, s) * dsdu / travel;
            float sp = length(vel);
            float2 d0 = sp > 1e-3 ? vel / sp : float2(0.0, 1.0);
            pos += float2(-d0.y, d0.x) * sin(p.d.y * 40.0 + t * 9.0) * p.d.z * s * (1.0 - s) * 4.0;
            absorb = smoothstep(0.80, 1.0, ltc);
        }

        float speed = length(vel);
        float2 dir = speed > 1e-3 ? vel / speed : float2(0.0, 1.0);
        float2 perp = float2(-dir.y, dir.x);
        float radius = p.d.x * (1.0 - 0.8 * absorb) * grow;
        float stretch = steam ? clamp(1.0 + speed / 2500.0, 1.0, 1.3) : clamp(1.0 + speed / 1100.0, 1.0, 2.4);
        float2 offset = dir * (corner.y * radius * stretch) + perp * (corner.x * radius / sqrt(stretch));
        float2 world = pos + offset;
        o.position = float4(world.x / u.view.x * 2.0 - 1.0, 1.0 - world.y / u.view.y * 2.0, 0.0, 1.0);
        o.age = clamp(tau / max(u.time.z, 0.05), 0.0, 1.0);
        // Growing puffs keep their total amount of steam: spread it over the larger area.
        o.strength = smoothstep(release - fade, release, t) * (1.0 - 0.9 * absorb) * fadeOut / (grow * grow);
        return o;
    }

    fragment float4 splatFragment(SplatOut in [[stage_in]]) {
        float d2 = dot(in.local, in.local);
        if (d2 >= 1.0) { discard_fragment(); }
        float k = 1.0 - d2;
        float w = (in.soft > 0.5 ? k * k : k * k * k) * in.strength;
        return float4(in.uv * w, w, in.age * w);
    }

    struct FullscreenOut { float4 position [[position]]; };

    vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
        FullscreenOut o;
        o.position = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        return o;
    }

    static float sdRoundRect(float2 p, float2 halfSize, float r) {
        float rr = min(r, min(halfSize.x, halfSize.y));
        float2 q = abs(p) - halfSize + rr;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    }

    static float3 unpremultiply(float4 c) {
        return c.a > 0.0001 ? c.rgb / c.a : float3(0.0);
    }

    /// Water height (0...1) from the field: steep at the edge like a meniscus, flat when deep.
    static float waterHeight(float field, float thr, float norm) {
        return sqrt(clamp((field - thr * 0.6) * norm * 1.5, 0.0, 1.0));
    }

    /// Light from the sky and the room: brighter towards the top.
    static float3 skyLight(float3 n) {
        return mix(float3(0.74, 0.82, 0.93), float3(1.0, 1.0, 1.0), smoothstep(-0.3, 0.7, -n.y));
    }

    static float fresnel(float3 n) {
        return 0.02 + 0.98 * pow(clamp(1.0 - n.z, 0.0, 1.0), 5.0);
    }

    fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                      texture2d<float> fluidTex [[texture(0)]],
                                      texture2d<float> windowTex [[texture(1)]],
                                      texture2d<float> backgroundTex [[texture(2)]],
                                      sampler zeroSampler [[sampler(0)]],
                                      sampler edgeSampler [[sampler(1)]],
                                      constant Uniforms& u [[buffer(0)]])
    {
        float2 viewSize = u.view.xy;
        float2 p = in.position.xy / u.view.zw;          // overlay points, top-left origin
        float2 suv = p / viewSize;
        float t = u.time.x;
        bool opaqueBg = u.misc.y > 0.5;
        bool steam = u.effect.x > 0.5;
        float onset = smoothstep(0.0, 0.08, t);

        float3 waterColor = clamp(u.water.rgb, 0.0, 1.0);
        float strength = clamp(u.water.a, 0.0, 1.0);
        // Absorption per unit depth: light of the water's own colour gets through best.
        float3 absorbCoef = -log(max(waterColor, float3(0.03))) * (0.3 + 2.2 * strength);
        float3 sun = normalize(float3(-0.45, -0.75, 0.55));
        float3 sunH = normalize(sun + float3(0.0, 0.0, 1.0));
        float3 fill = normalize(float3(0.6, -0.3, 0.75));
        float3 fillH = normalize(fill + float3(0.0, 0.0, 1.0));

        // ---- ripples where the water drains into the Dock ----
        float2 toTarget = p - u.points.xy;
        float dTarget = length(toTarget);
        float activity = smoothstep(u.dock.x - 0.05, u.dock.x + 0.12, t)
                       * (1.0 - smoothstep(u.dock.y - 0.15, u.dock.y + 0.08, t));
        float ringEnv = exp(-dTarget / 45.0) * activity;
        float ringWave = sin(dTarget * 0.32 - t * 16.0);
        float2 dockOffset = (dTarget > 0.5 ? toTarget / dTarget : float2(0.0)) * ringWave * ringEnv * 3.0;

        // ---- water surface from the metaball field ----
        float thr = u.misc.x;
        float norm = u.fluid.z;
        float4 F = fluidTex.sample(edgeSampler, suv);
        float field = F.b;
        float cover = smoothstep(thr * 0.55, thr * 1.25, field);
        float2 tx = u.fluid.xy * 1.5;
        float h = waterHeight(field, thr, norm);
        float hl = waterHeight(fluidTex.sample(edgeSampler, suv - float2(tx.x, 0.0)).b, thr, norm);
        float hr = waterHeight(fluidTex.sample(edgeSampler, suv + float2(tx.x, 0.0)).b, thr, norm);
        float hu = waterHeight(fluidTex.sample(edgeSampler, suv - float2(0.0, tx.y)).b, thr, norm);
        float hd = waterHeight(fluidTex.sample(edgeSampler, suv + float2(0.0, tx.y)).b, thr, norm);
        float2 grad = float2(hr - hl, hd - hu) / 3.0;                 // per point
        float curvature = hl + hr + hu + hd - 4.0 * h;                // < 0 on a dome: focuses light
        float deep = smoothstep(0.6, 1.0, h);
        float2 ripples = float2(sin(p.y * 0.19 + t * 7.0) + sin(p.x * 0.11 - t * 5.0 + p.y * 0.05),
                                cos(p.x * 0.16 + t * 6.0) + cos(p.y * 0.09 - t * 4.0)) * 0.05 * deep;
        float3 n = normalize(float3(-grad * 9.0 + ripples, 1.0));
        float fres = fresnel(n);
        float glint = pow(max(dot(n, sunH), 0.0), 220.0) * 2.2
                    + pow(max(dot(n, sunH), 0.0), 28.0) * 0.10
                    + pow(max(dot(n, fillH), 0.0), 70.0) * 0.22;
        float caustic = clamp(-curvature * 2.6, 0.0, 1.0) * h;
        float depth = h * (0.5 + 1.5 * strength);
        float3 transmittance = exp(-absorbCoef * depth);
        float3 env = skyLight(n);

        // ---- background ----
        float4 color;
        float3 transmitted = float3(0.0);
        if (opaqueBg) {
            // Refraction through the curved surface, with a hint of dispersion.
            float2 refr = -n.xy * (8.0 + 18.0 * h) + dockOffset;
            float rr = backgroundTex.sample(edgeSampler, (p + refr) / viewSize).r;
            float rg = backgroundTex.sample(edgeSampler, (p + refr * 1.06) / viewSize).g;
            float rb = backgroundTex.sample(edgeSampler, (p + refr * 1.12) / viewSize).b;
            transmitted = float3(rr, rg, rb) * transmittance + waterColor * (1.0 - transmittance) * 0.25;
            env = mix(env, backgroundTex.sample(edgeSampler, (p + n.xy * 70.0) / viewSize).rgb, 0.4);
            float3 bg = backgroundTex.sample(edgeSampler, (p + dockOffset) / viewSize).rgb;
            // The water casts a faint shadow (light comes from the top-left).
            float shadowField = fluidTex.sample(edgeSampler, (p - float2(5.0, 7.0)) / viewSize).b;
            float waterShadow = steam ? 0.0 : smoothstep(thr * 0.5, thr * 2.0, shadowField) * 0.16 * (1.0 - cover);
            color = float4(bg * (1.0 - waterShadow), 1.0);
        } else {
            float g = smoothstep(0.75, 1.0, ringWave) * ringEnv * 0.35;
            color = float4(float3(0.8, 0.92, 1.0) * g, g);
        }

        // ---- soft shadow under the part of the window that is still solid ----
        float sag = sagAt(t, u);
        float solidFraction = clamp(1.0 - (t - u.melt.x) / u.melt.y, 0.0, 1.0);
        {
            float2 halfSize = float2(u.win.z, u.win.w * (steam ? 1.0 : solidFraction)) * 0.5;
            float2 center = u.win.xy + float2(halfSize.x, halfSize.y + sag + 10.0);
            float d = sdRoundRect(p - center, halfSize, u.misc.z);
            float shadow = 0.30 * (1.0 - smoothstep(-8.0, 30.0, d)) * smoothstep(0.0, 0.05, solidFraction);
            color = float4(color.rgb * (1.0 - shadow), shadow + color.a * (1.0 - shadow));
        }

        // ---- steam ----
        if (steam && field > 0.001) {
            float density = field * norm;
            float2 g = float2(fluidTex.sample(edgeSampler, suv + float2(tx.x, 0.0)).b - fluidTex.sample(edgeSampler, suv - float2(tx.x, 0.0)).b,
                              fluidTex.sample(edgeSampler, suv + float2(0.0, tx.y)).b - fluidTex.sample(edgeSampler, suv - float2(0.0, tx.y)).b) * norm;
            float w = max(field, 1e-4);
            float age = clamp(F.a / w, 0.0, 1.0);
            float3 imgRGB = unpremultiply(windowTex.sample(zeroSampler, F.rg / w));
            float whiten = smoothstep(0.0, 0.7, age);
            // Lit from above: the top of a cloud is brighter, the underside a little grey.
            float light = clamp(0.95 + g.y * 0.8, 0.8, 1.06);
            float3 steamRGB = mix(imgRGB, float3(0.93, 0.95, 0.98), whiten) * light;
            float a = clamp(1.0 - exp(-density * 1.4), 0.0, 0.85) * mix(1.0, 0.72, whiten);
            if (opaqueBg) {
                // Heat haze: the background trembles where the hot steam is.
                float2 haze = float2(sin(p.y * 0.25 - t * 14.0), cos(p.x * 0.21 + t * 11.0)) * 2.5 * min(density, 1.0) + g * 6.0;
                float3 hazy = backgroundTex.sample(edgeSampler, (p + haze) / viewSize).rgb;
                color.rgb = mix(color.rgb, hazy, min(density * 2.0, 1.0));
            }
            color.rgb = min(steamRGB, 1.0) * a + color.rgb * (1.0 - a);
            color.a = a + color.a * (1.0 - a);
        }

        // ---- water ----
        if (!steam && cover > 0.002) {
            float w = max(field, 1e-4);
            float2 avgUV = F.rg / w;
            float age = clamp(F.a / w, 0.0, 1.0);
            float4 img = windowTex.sample(zeroSampler, avgUV);
            float3 imgRGB = unpremultiply(img);
            float dissolve = max(smoothstep(0.05, 0.9, age), 1.0 - smoothstep(0.05, 0.6, img.a));
            float edge = smoothstep(0.25, 0.95, 1.0 - n.z);
            float3 rgb;
            float a;
            if (opaqueBg) {
                float3 water = mix(transmitted, env, clamp(fres * 1.5, 0.0, 1.0));
                water *= 1.0 - 0.3 * edge;                                    // dark meniscus
                water += caustic * (0.35 + 0.65 * waterColor) * 0.5;
                rgb = mix(imgRGB, water, dissolve) + glint;
                a = cover;
            } else {
                // No background to refract: translucent water of the chosen colour.
                float body = 0.2 + 0.65 * (1.0 - (transmittance.r + transmittance.g + transmittance.b) / 3.0);
                float aw = clamp(body * (1.0 - fres) + fres * 0.85, 0.0, 1.0);
                float3 bodyRGB = waterColor * (0.55 + 0.45 * h);
                float3 water = (bodyRGB * body * (1.0 - fres) + env * fres * 0.85) / max(aw, 1e-3);
                water *= 1.0 - 0.25 * edge;
                water += caustic * 0.3;
                rgb = mix(imgRGB, water, dissolve) + glint;
                a = clamp(cover * mix(1.0, aw, dissolve) + glint * cover * 0.6, 0.0, 1.0);
            }
            color.rgb = min(rgb, 1.0) * a + color.rgb * (1.0 - a);
            color.a = a + color.a * (1.0 - a);
        }

        // ---- the part of the window that is still solid ----
        float2 q = (p - u.win.xy - float2(0.0, sag)) / u.win.zw;
        if (q.x > -0.03 && q.x < 1.03 && q.y > -0.03 && q.y < 1.03) {
            float release = releaseTime(clamp(q, 0.0, 1.0), u);
            if (t < release) {
                float pre = smoothstep(release - 0.38, release, t) * onset;
                // Ripple running over the window from the clicked button.
                float2 toR = p - u.points.zw;
                float dR = length(toR);
                float front = t * 900.0;
                float x = (dR - front) / 70.0;
                float env2 = exp(-x * x) * exp(-t * 2.5) * onset * u.time.w;
                float2 rdir = dR > 0.5 ? toR / dR : float2(0.0);
                float wave = sin((dR - front) * 0.12);
                // A wet, moving water surface that grows as the melt approaches.
                float2 wet = float2(sin(q.y * 31.0 + t * 9.0) * cos(q.x * 17.0 - t * 4.0),
                                    cos(q.x * 27.0 + t * 7.0) * sin(q.y * 13.0 + t * 5.0));
                float3 ns = normalize(float3(wet * 0.45 * pre + rdir * wave * env2 * 0.5, 1.0));
                float2 offset = rdir * wave * env2 * 5.0 + ns.xy * 7.0 * pre;
                if (steam) {
                    // Heat shimmer: the window trembles like air above a hot road.
                    offset = rdir * wave * env2 * 5.0
                           + float2(sin(q.y * 60.0 - t * 30.0 + q.x * 8.0), sin(q.x * 45.0 + t * 22.0)) * pre * 2.2;
                }
                float4 s = windowTex.sample(zeroSampler, q + offset / u.win.zw);
                float3 rgb = unpremultiply(s);
                if (steam) {
                    float lum = dot(rgb, float3(0.299, 0.587, 0.114));
                    rgb = mix(rgb, mix(float3(lum), float3(1.0), 0.35), pre * 0.45);       // heated, washed out
                    float condensing = smoothstep(release - 0.08, release, t);
                    rgb = mix(rgb, float3(0.97, 0.98, 1.0), condensing * 0.55);              // turns to vapour
                    float a = s.a * smoothstep(0.0, u.misc.w, release - t);
                    color.rgb = min(rgb, 1.0) * a + color.rgb * (1.0 - a);
                    color.a = a + color.a * (1.0 - a);
                    return color;
                }
                // Just before melting the window turns glassy: you start to see through it.
                if (opaqueBg) {
                    float3 behind = backgroundTex.sample(edgeSampler, (p - ns.xy * 14.0) / viewSize).rgb;
                    behind = behind * exp(-absorbCoef * 0.6) + waterColor * 0.08;
                    rgb = mix(rgb, behind, pre * 0.4);
                }
                rgb = mix(rgb, rgb * mix(float3(1.0), waterColor, 0.6), pre * 0.35);
                float fresS = fresnel(ns) * pre;
                float glintS = pow(max(dot(ns, sunH), 0.0), 160.0) * 1.4 * pre
                             + env2 * max(0.0, wave) * 0.08;
                rgb = mix(rgb, skyLight(ns), fresS) + glintS;
                float a = s.a * smoothstep(0.0, u.misc.w, release - t) * (opaqueBg ? 1.0 : 1.0 - 0.25 * pre);
                rgb = min(rgb, 1.0);
                color.rgb = rgb * a + color.rgb * (1.0 - a);
                color.a = a + color.a * (1.0 - a);
            }
        }
        return color;
    }
    """
}
