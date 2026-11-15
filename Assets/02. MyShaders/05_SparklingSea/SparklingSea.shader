// ─────────────────────────────────────────────────────────────────────────────
// SparklingSea — 달빛 윤슬이 반짝이는 몽환적인 밤바다 (URP, HLSL)
//
//  1) 파도      : 게르스트너 파도 4개를 더해 정점을 움직인다. 위아래뿐 아니라 앞뒤로도 움직여
//                 마루는 뾰족하고 골은 넓은 실제 파도 모양이 된다. 법선도 같은 수식의 미분으로 계산
//  2) 잔물결    : 픽셀 단위로 사인파 4개의 기울기를 더해 법선을 흔든다 (텍스처 없는 노멀맵)
//  3) 반사      : 프레넬 — 비스듬히 볼수록 하늘(밤하늘 색 + 달)을 비추고, 내려다보면 물 색
//  4) 윤슬      : 수면을 작은 칸으로 나누고 칸마다 법선을 무작위로 기울여, 달을 정확히 반사하는
//                 칸만 반짝인다 → 달 아래로 길게 흩어지는 달빛 길
//  5) 꿈 반짝이 : 달과 상관없이 드문드문 별처럼 깜빡이는 파스텔 빛
//  6) 물가 거품 : 깊이 텍스처(불투명 물체까지의 거리)와 수면까지의 거리 차이가 작은 곳 = 물체와
//                 닿는 곳. 그곳에 노이즈로 끊긴 거품과, 물가로 밀려오는 거품 줄무늬를 그린다
//  7) 깊이 색   : 같은 깊이 차이로 얕은 곳은 밝고 투명하게, 깊은 곳은 어둡고 불투명하게
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/SparklingSea"
{
    Properties
    {
        [Header(Water Color)]
        _ShallowColor ("Shallow Color", Color) = (0.62, 0.93, 1, 1)
        _DeepColor ("Deep Color", Color) = (0.24, 0.58, 0.92, 1)
        _DepthRange ("Depth Range", Float) = 2.5
        _ShallowAlpha ("Shallow Alpha", Range(0, 1)) = 0.5

        [Header(Gerstner Waves (dir.xy steepness wavelength))]
        _WaveA ("Wave A", Vector) = (1, 0.3, 0.10, 12)
        _WaveB ("Wave B", Vector) = (-0.4, 1, 0.08, 7)
        _WaveC ("Wave C", Vector) = (0.7, 0.8, 0.06, 4.1)
        _WaveD ("Wave D", Vector) = (-0.8, -0.2, 0.04, 2.3)
        _WaveSpeed ("Wave Speed", Float) = 0.5

        [Header(Ripples)]
        _RippleScale ("Ripple Scale", Float) = 2.5
        _RippleStrength ("Ripple Strength", Range(0, 1)) = 0.25
        _RippleSpeed ("Ripple Speed", Float) = 1.2

        [Header(Sky Reflection)]
        _SkyZenithColor ("Sky Zenith Color", Color) = (0.35, 0.5, 0.85, 1)
        _SkyHorizonColor ("Sky Horizon Color", Color) = (0.75, 0.85, 0.98, 1)
        _ReflectionStrength ("Reflection Strength", Range(0, 1)) = 0.55
        _DetailFadeDistance ("Detail Fade Distance", Float) = 35

        [Header(Moon)]
        _MoonDirection ("Moon Direction", Vector) = (-0.5, 0.35, 0.8, 0)
        [HDR] _MoonColor ("Moon Color", Color) = (2.2, 2.0, 2.4, 1)
        _MoonSpecPower ("Moon Highlight Power", Float) = 300

        [Header(Moon Glitter)]
        [HDR] _GlitterColor ("Glitter Color", Color) = (2.5, 3.0, 4.0, 1)
        _GlitterDensity ("Glitter Density", Float) = 8
        _GlitterSpread ("Glitter Normal Spread", Range(0, 1)) = 0.3
        _GlitterPower ("Glitter Sharpness", Float) = 150
        _GlitterSpeed ("Glitter Blink Speed", Float) = 5

        [Header(Dream Sparkles)]
        [HDR] _SparkleColor ("Sparkle Color", Color) = (2.5, 3.5, 5.0, 1)
        _SparkleDensity ("Sparkle Density", Float) = 4
        _SparkleAmount ("Sparkle Amount", Range(0, 1)) = 0.22
        _SparkleSpeed ("Sparkle Speed", Float) = 2

        [Header(Shore Foam)]
        [HDR] _FoamColor ("Foam Color", Color) = (0.9, 1.1, 1.5, 1)
        _FoamDistance ("Foam Distance", Float) = 0.4
        _FoamNoiseScale ("Foam Noise Scale", Float) = 4
        _FoamLineSpeed ("Foam Line Speed", Float) = 0.5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Transparent"
            "Queue" = "Transparent-10"   // 물을 먼저 그려야 물에 반쯤 잠긴 투명 물체(정령 볼)의 물속 부분이 가려진다
        }

        Pass
        {
            Name "Sea"
            Tags { "LightMode" = "UniversalForward" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite On
            Cull Back

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4  _ShallowColor;
                half4  _DeepColor;
                float  _DepthRange;
                half   _ShallowAlpha;
                float4 _WaveA;
                float4 _WaveB;
                float4 _WaveC;
                float4 _WaveD;
                float  _WaveSpeed;
                float  _RippleScale;
                half   _RippleStrength;
                float  _RippleSpeed;
                half4  _SkyZenithColor;
                half4  _SkyHorizonColor;
                half   _ReflectionStrength;
                float  _DetailFadeDistance;
                float4 _MoonDirection;
                half4  _MoonColor;
                float  _MoonSpecPower;
                half4  _GlitterColor;
                float  _GlitterDensity;
                half   _GlitterSpread;
                float  _GlitterPower;
                float  _GlitterSpeed;
                half4  _SparkleColor;
                float  _SparkleDensity;
                half   _SparkleAmount;
                float  _SparkleSpeed;
                half4  _FoamColor;
                float  _FoamDistance;
                float  _FoamNoiseScale;
                float  _FoamLineSpeed;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS  : SV_POSITION;
                float3 positionWS  : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float4 positionNDC : TEXCOORD2;
            };

            // ── 해시 & 노이즈 ───────────────────────────────────────────────
            float3 Hash32(float2 p)
            {
                float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
                p3 += dot(p3, p3.yxz + 33.33);
                return frac((p3.xxy + p3.yzz) * p3.zyx);
            }

            float ValueNoise2(float2 p)
            {
                float2 i = floor(p);
                float2 f = frac(p);
                float2 u = f * f * (3.0 - 2.0 * f);
                float a = Hash32(i).x;
                float b = Hash32(i + float2(1, 0)).x;
                float c = Hash32(i + float2(0, 1)).x;
                float d = Hash32(i + float2(1, 1)).x;
                return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
            }

            // ── 1. 게르스트너 파도 ──────────────────────────────────────────
            // wave = (방향 x, 방향 y, 가파름, 파장). 점을 원 궤도로 움직여 마루가 뾰족해진다.
            float3 GerstnerWave(float4 wave, float3 p, inout float3 tangent, inout float3 binormal)
            {
                float  steepness  = wave.z;
                float  wavelength = wave.w;
                float  k = TWO_PI / wavelength;          // 파수
                float  c = sqrt(9.8 / k);                // 깊은 물에서의 파도 속도 (물리식)
                float2 d = normalize(wave.xy);
                float  f = k * (dot(d, p.xz) - c * _Time.y * _WaveSpeed);
                float  a = steepness / k;                // 진폭
                float  s, co;
                sincos(f, s, co);

                // 위치를 x, z 로 미분한 값을 누적 → 나중에 외적해서 법선을 얻는다
                tangent  += float3(-d.x * d.x * steepness * s, d.x * steepness * co, -d.x * d.y * steepness * s);
                binormal += float3(-d.x * d.y * steepness * s, d.y * steepness * co, -d.y * d.y * steepness * s);
                return float3(d.x * a * co, a * s, d.y * a * co);
            }

            Varyings Vert(Attributes v)
            {
                Varyings o;
                float3 p = TransformObjectToWorld(v.positionOS.xyz);   // 월드 좌표로 계산 → 메시를 여러 장 이어도 파도가 이어진다

                float3 tangent  = float3(1, 0, 0);
                float3 binormal = float3(0, 0, 1);
                float3 offset = 0;
                offset += GerstnerWave(_WaveA, p, tangent, binormal);
                offset += GerstnerWave(_WaveB, p, tangent, binormal);
                offset += GerstnerWave(_WaveC, p, tangent, binormal);
                offset += GerstnerWave(_WaveD, p, tangent, binormal);
                p += offset;

                o.positionWS  = p;
                o.normalWS    = normalize(cross(binormal, tangent));
                o.positionCS  = TransformWorldToHClip(p);
                o.positionNDC = ComputeScreenPos(o.positionCS);
                return o;
            }

            // 별/윤슬이 화면에서 한 픽셀보다 작아지면 깜빡거림(에일리어싱)이 생기므로 멀리서는 줄인다
            float CellFade(float2 cellCoord)
            {
                float2 w = fwidth(cellCoord);
                float  pixelsPerCell = 1.0 / max(max(w.x, w.y), 1e-4);
                return saturate(pixelsPerCell / 6.0 - 0.5);
            }

            half3 SkyColor(float3 dir)
            {
                return lerp(_SkyHorizonColor.rgb, _SkyZenithColor.rgb, smoothstep(0.0, 0.6, dir.y));
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float  t     = _Time.y;
                float3 posWS = i.positionWS;
                float3 V     = GetWorldSpaceNormalizeViewDir(posWS);
                float3 moonDir = normalize(_MoonDirection.xyz);

                // ── 2. 잔물결: 사인파 4개의 기울기(미분)를 더해 법선을 흔든다 ─────
                float2 rp = posWS.xz * _RippleScale;
                float2 grad = 0;
                const float2 dirs[4] = { float2(1, 0.2), float2(-0.3, 1), float2(0.7, -0.7), float2(-0.9, -0.4) };
                const float  freqs[4] = { 1.0, 1.37, 1.83, 2.41 };
                [unroll] for (int k = 0; k < 4; k++)
                {
                    float2 d = normalize(dirs[k]);
                    float  phase = dot(d, rp) * freqs[k] + t * _RippleSpeed * (1.0 + k * 0.3);
                    grad += d * freqs[k] * cos(phase) / (k + 1.0);
                }
                // 멀리 갈수록 잔물결을 약하게 → 수평선 근처가 지글거리지 않게
                float camDist = distance(posWS, _WorldSpaceCameraPos);
                float detail  = saturate(1.0 - camDist / _DetailFadeDistance);
                float3 N = normalize(i.normalWS + float3(-grad.x, 0, -grad.y) * _RippleStrength * detail);
                // 파도 법선도 멀리서는 평평하게 (멀리 있는 작은 파도가 픽셀보다 작아져 생기는 노이즈 감소)
                N = normalize(lerp(float3(0, 1, 0), N, 0.35 + 0.65 * detail));

                // ── 3. 프레넬 반사 (Schlick 근사, 물의 F0 ≈ 0.02) ─────────────
                float  NdotV   = saturate(dot(N, V));
                float  fresnel = 0.02 + 0.98 * pow(1.0 - NdotV, 5.0);
                float3 R       = reflect(-V, N);
                half3  reflection = SkyColor(R) + pow(saturate(dot(R, moonDir)), _MoonSpecPower) * _MoonColor.rgb;

                // ── 6~7. 깊이: 수면 뒤 불투명 물체까지의 거리 ──────────────────
                float2 screenUV   = i.positionNDC.xy / i.positionNDC.w;
                float  sceneDepth = LinearEyeDepth(SampleSceneDepth(screenUV), _ZBufferParams);
                float  waterDepth = i.positionNDC.w;                  // 수면까지의 시선 거리
                float  depthDiff  = max(sceneDepth - waterDepth, 0.0); // 물속 깊이 (시선 방향)
                float  depth01    = saturate(depthDiff / _DepthRange);

                // 물 자체의 색: 얕으면 밝은 청록, 깊으면 남보라 + 부드러운 조명
                Light mainLight = GetMainLight();
                half  halfLambert = dot(N, mainLight.direction) * 0.5 + 0.5;
                half3 waterColor = lerp(_ShallowColor.rgb, _DeepColor.rgb, depth01);
                waterColor *= 0.6 + 0.4 * halfLambert * mainLight.color;
                waterColor += SampleSH(N) * 0.1;

                half3 color = lerp(waterColor, reflection, fresnel * _ReflectionStrength);

                // ── 4. 달빛 윤슬 ─────────────────────────────────────────────
                float2 gCoord = posWS.xz * _GlitterDensity;
                float2 gCell  = floor(gCoord);
                float3 gRnd   = Hash32(gCell);
                // 칸마다 법선을 무작위로 기울인 뒤, 그 법선으로 반사한 방향이 달을 향하면 반짝
                float3 gN     = normalize(N + float3(gRnd.x - 0.5, 0, gRnd.y - 0.5) * _GlitterSpread);
                float  gSpec  = pow(saturate(dot(reflect(-V, gN), moonDir)), _GlitterPower);
                float  gDot   = 1.0 - smoothstep(0.03, 0.16, length(frac(gCoord) - (gRnd.yx * 0.5 + 0.25)));
                float  gBlink = 0.5 + 0.5 * sin(t * _GlitterSpeed * (0.5 + gRnd.z) + gRnd.x * 40.0);
                float  glitter = gSpec * gDot * gBlink * CellFade(gCoord);
                color += glitter * _GlitterColor.rgb;

                // ── 5. 꿈 반짝이 ─────────────────────────────────────────────
                float2 sCoord = posWS.xz * _SparkleDensity + float2(0, t * 0.05);
                float2 sCell  = floor(sCoord);
                float3 sRnd   = Hash32(sCell + 71.3);
                float  sOn    = step(1.0 - _SparkleAmount, sRnd.x);
                float  sBlink = pow(saturate(sin(t * _SparkleSpeed * (0.5 + sRnd.y) + sRnd.z * 6.2832)), 12.0);
                float  sDot   = 1.0 - smoothstep(0.0, 0.15, length(frac(sCoord) - (sRnd.zy * 0.5 + 0.25)));
                float  sparkle = sOn * sBlink * sDot * CellFade(sCoord);
                color += sparkle * _SparkleColor.rgb;

                // ── 6. 물가 거품 ─────────────────────────────────────────────
                float foamMask  = 1.0 - saturate(depthDiff / _FoamDistance);   // 물체에 가까울수록 1
                float foamNoise = ValueNoise2(posWS.xz * _FoamNoiseScale + float2(t * 0.3, -t * 0.2));
                float foamCore  = smoothstep(foamNoise - 0.08, foamNoise + 0.08, foamMask * 1.1);
                // 물가로 밀려오는 줄무늬: 깊이 차이를 따라 반복하는 띠를 시간에 따라 이동
                float foamLines = smoothstep(0.75, 0.95, frac(foamMask * 3.0 + t * _FoamLineSpeed + foamNoise * 0.5));
                float foam = saturate(max(foamCore * 0.8, foamLines * foamMask * 0.6));
                color = lerp(color, _FoamColor.rgb, foam);

                // ── 투명도: 얕은 곳은 비치고, 깊거나 비스듬하면 불투명 ───────────
                half alpha = lerp(_ShallowAlpha, 1.0, depth01);
                alpha = saturate(max(alpha, fresnel) + foam + glitter + sparkle);

                return half4(color, alpha);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
