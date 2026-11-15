// ─────────────────────────────────────────────────────────────────────────────
// DreamyNightSky — 오로라가 일렁이고 별이 반짝이는 몽환적인 밤하늘 스카이박스 (URP, HLSL)
//
//  텍스처 없이 '하늘을 바라보는 방향 벡터' 하나로 모든 것을 계산한다.
//  1) 그라데이션 : 방향의 높이(y)로 지평선 → 중간 → 천정 3단 색을 섞는다
//  2) 별        : 방향을 3D 격자로 쪼개고, 칸마다 해시로 별의 유무/위치/크기/색을 정한다.
//                 sin(시간 + 칸별 난수)로 별마다 다른 박자로 깜빡인다
//  3) 오로라     : 방향을 가상의 하늘 평면에 투영한 좌표에 노이즈 + 사인파를 더해
//                 구불구불한 띠를 만들고, 세로 줄무늬 노이즈로 커튼처럼 보이게 한다
//  4) 달        : 달 방향과의 각도로 원판과 은은한 빛무리를 그린다
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/DreamyNightSky"
{
    Properties
    {
        [Header(Sky Gradient)]
        _ZenithColor ("Zenith Color", Color) = (0.14, 0.13, 0.38, 1)
        _MidColor ("Mid Color", Color) = (0.38, 0.32, 0.65, 1)
        _HorizonColor ("Horizon Color", Color) = (0.88, 0.66, 0.88, 1)
        _GroundColor ("Ground Color", Color) = (0.15, 0.12, 0.25, 1)
        _HorizonHeight ("Horizon Band Height", Range(0.01, 1)) = 0.3

        [Header(Stars)]
        [HDR] _StarColor ("Star Color", Color) = (1.5, 1.4, 1.8, 1)
        _StarDensity ("Star Density", Float) = 70
        _StarProbability ("Star Probability", Range(0, 1)) = 0.35
        _StarSize ("Star Size", Range(0.02, 0.3)) = 0.14
        _TwinkleSpeed ("Twinkle Speed", Float) = 2.5

        [Header(Aurora)]
        [HDR] _AuroraColorA ("Aurora Color (Bottom)", Color) = (0.2, 1.6, 1.0, 1)
        [HDR] _AuroraColorB ("Aurora Color (Top)", Color) = (1.3, 0.3, 1.6, 1)
        _AuroraIntensity ("Aurora Intensity", Range(0, 3)) = 0.55
        _AuroraScale ("Aurora Scale", Float) = 1
        _AuroraSpeed ("Aurora Speed", Float) = 0.15
        _AuroraSharpness ("Aurora Band Sharpness", Range(0.2, 6)) = 2.5
        _AuroraHeight ("Aurora Max Height", Range(0.1, 0.9)) = 0.55
        _AuroraSpacing ("Aurora Ribbon Spacing", Float) = 3.2

        [Header(Moon)]
        _MoonDirection ("Moon Direction", Vector) = (-0.5, 0.35, 0.8, 0)
        [HDR] _MoonColor ("Moon Color", Color) = (2.2, 2.0, 2.4, 1)
        _MoonSize ("Moon Size (rad)", Range(0.005, 0.2)) = 0.045
        _MoonGlow ("Moon Glow", Range(0, 2)) = 0.6
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Background"
            "Queue" = "Background"
            "PreviewType" = "Skybox"
        }
        Cull Off
        ZWrite Off

        Pass
        {
            Name "NightSky"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4  _ZenithColor;
                half4  _MidColor;
                half4  _HorizonColor;
                half4  _GroundColor;
                half   _HorizonHeight;
                half4  _StarColor;
                float  _StarDensity;
                half   _StarProbability;
                half   _StarSize;
                float  _TwinkleSpeed;
                half4  _AuroraColorA;
                half4  _AuroraColorB;
                half   _AuroraIntensity;
                float  _AuroraScale;
                float  _AuroraSpeed;
                half   _AuroraSharpness;
                half   _AuroraHeight;
                float  _AuroraSpacing;
                float4 _MoonDirection;
                half4  _MoonColor;
                half   _MoonSize;
                half   _MoonGlow;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 viewDir    : TEXCOORD0;
            };

            // ── 해시 & 노이즈 ───────────────────────────────────────────────
            float Hash31(float3 p)
            {
                p = frac(p * 0.1031);
                p += dot(p, p.zyx + 31.32);
                return frac((p.x + p.y) * p.z);
            }

            float3 Hash33(float3 p)
            {
                p = frac(p * float3(0.1031, 0.1030, 0.0973));
                p += dot(p, p.yxz + 33.33);
                return frac((p.xxy + p.yxx) * p.zyx);
            }

            float Hash21(float2 p)
            {
                float3 p3 = frac(float3(p.xyx) * 0.1031);
                p3 += dot(p3, p3.yzx + 33.33);
                return frac((p3.x + p3.y) * p3.z);
            }

            float ValueNoise2(float2 p)
            {
                float2 i = floor(p);
                float2 f = frac(p);
                float2 u = f * f * (3.0 - 2.0 * f);
                float a = Hash21(i);
                float b = Hash21(i + float2(1, 0));
                float c = Hash21(i + float2(0, 1));
                float d = Hash21(i + float2(1, 1));
                return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
            }

            float Fbm2(float2 p)
            {
                float v = 0.0;
                float a = 0.5;
                [unroll] for (int k = 0; k < 4; k++)
                {
                    v += a * ValueNoise2(p);
                    p = p * 2.07 + 13.7;
                    a *= 0.5;
                }
                return v / 0.9375;
            }

            Varyings Vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                // 스카이박스 메시는 카메라를 둘러싼 구/큐브이므로 정점 위치 = 바라보는 방향
                o.viewDir = v.positionOS.xyz;
                return o;
            }

            // ── 1. 하늘 그라데이션 ────────────────────────────────────────────
            half3 SkyGradient(float y)
            {
                half3 upper = lerp(_HorizonColor.rgb, _MidColor.rgb, smoothstep(0.0, _HorizonHeight, y));
                upper = lerp(upper, _ZenithColor.rgb, smoothstep(_HorizonHeight, 1.0, y));
                half3 lower = lerp(_HorizonColor.rgb * 0.6, _GroundColor.rgb, smoothstep(0.0, -0.25, y));
                return y >= 0.0 ? upper : lower;
            }

            // ── 2. 별 ───────────────────────────────────────────────────────
            half3 Stars(float3 dir)
            {
                float3 p    = dir * _StarDensity;
                float3 cell = floor(p);
                float3 f    = frac(p);

                float3 rnd = Hash33(cell);              // 칸마다 고정된 난수 3개
                float  has = step(Hash31(cell + 11.7), _StarProbability);   // 이 칸에 별이 있는가

                float3 starPos = rnd * 0.6 + 0.2;       // 칸 경계에 잘리지 않도록 0.2~0.8 안쪽
                float  dist    = length(f - starPos);
                float  size    = _StarSize * (0.4 + rnd.x);
                float  core    = saturate(1.0 - dist / size);
                core = core * core * core;              // 가운데가 뾰족하게 밝은 점

                // 별마다 박자와 위상이 다른 깜빡임
                float twinkle = 0.55 + 0.45 * sin(_Time.y * _TwinkleSpeed * (0.5 + rnd.y) + rnd.z * TWO_PI);

                // 별 색에 푸른/분홍 기운을 살짝 섞는다
                half3 tint = lerp(half3(0.75, 0.85, 1.2), half3(1.2, 0.8, 1.0), rnd.z);
                return has * core * twinkle * tint * _StarColor.rgb;
            }

            // ── 3. 오로라 ───────────────────────────────────────────────────
            half3 Aurora(float3 dir)
            {
                float y = dir.y;
                // 지평선 바로 위에서 생겨 AuroraHeight 위로는 사라진다
                float heightMask = smoothstep(0.02, 0.12, y) * (1.0 - smoothstep(_AuroraHeight, _AuroraHeight + 0.3, y));
                if (heightMask <= 0.0) return 0;

                // 하늘에 떠 있는 평면에 투영 → 위로 갈수록 좌표가 작아져 원근감이 생긴다
                float2 uv = dir.xz / (y + 0.25) * _AuroraScale;
                float  t  = _Time.y * _AuroraSpeed;

                half3 result = 0;
                [unroll] for (int layer = 0; layer < 2; layer++)
                {
                    float2 luv  = uv * (1.0 + layer * 0.35) + layer * 4.3;
                    float  warp = Fbm2(luv * 0.6 + float2(t * 0.3, t * 0.1));
                    // 사인파 곡선 + 노이즈 휘어짐 = 구불구불한 띠의 중심선
                    float  curve = luv.y + sin(luv.x * 0.9 + t * (1.0 + layer)) * 0.6 + (warp - 0.5) * 2.2;
                    // 띠를 Spacing 간격으로 반복 → 하늘 어느 방향을 봐도 오로라가 보인다
                    float  ribbonId = floor(curve / _AuroraSpacing + 0.5);
                    curve = curve - ribbonId * _AuroraSpacing;
                    float  band  = exp(-curve * curve * _AuroraSharpness);
                    band *= 0.6 + 0.4 * frac(sin(ribbonId * 12.9898 + layer * 4.1) * 43758.5453);   // 띠마다 밝기를 조금 다르게
                    // 세로 줄무늬: x 방향으로만 촘촘하게 변하는 노이즈 → 커튼의 주름
                    float  streak = Fbm2(float2(luv.x * 3.0 + warp * 2.0, t * 2.0));
                    streak = pow(saturate(streak), 1.5) * 1.8;
                    result += band * streak * (layer == 0 ? 1.0 : 0.6);
                }

                half3 color = lerp(_AuroraColorA.rgb, _AuroraColorB.rgb, saturate(y / _AuroraHeight));
                return result * color * heightMask * _AuroraIntensity;
            }

            // ── 4. 달 ───────────────────────────────────────────────────────
            half3 Moon(float3 dir)
            {
                float3 moonDir = normalize(_MoonDirection.xyz);
                float  angle   = acos(clamp(dot(dir, moonDir), -1.0, 1.0));    // 달 중심과의 각도(라디안)
                float  disc    = 1.0 - smoothstep(_MoonSize * 0.9, _MoonSize, angle);
                // 빛무리: 달 크기의 약 3배 범위에서 부드럽게 사라지는 가우시안
                float  glow    = exp(-angle * angle / (_MoonSize * _MoonSize * 6.0)) * _MoonGlow;
                return disc * _MoonColor.rgb + glow * _MoonColor.rgb * 0.35;
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float3 dir = normalize(i.viewDir);

                half3 color = SkyGradient(dir.y);

                half3 aurora = Aurora(dir);
                float aboveHorizon = smoothstep(-0.02, 0.2, dir.y);
                // 오로라가 밝은 곳은 별을 조금 가린다
                half  auroraLum = saturate(dot(aurora, half3(0.33, 0.33, 0.33)));
                color += Stars(dir) * aboveHorizon * (1.0 - auroraLum * 0.7);
                color += aurora;
                color += Moon(dir) * aboveHorizon;

                // 지평선 근처의 옅은 안개 빛
                color += _HorizonColor.rgb * exp(-abs(dir.y) * 12.0) * 0.25;

                return half4(color, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
