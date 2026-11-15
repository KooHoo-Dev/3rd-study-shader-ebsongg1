// ─────────────────────────────────────────────────────────────────────────────
// DreamyScreenFilter — 꿈결 화면 필터 (URP 전체 화면 후처리, HLSL)
//
//  카메라가 다 그린 화면(_BlitTexture)을 한 장의 이미지로 받아 다시 그린다.
//  URP Renderer 의 "Full Screen Pass Renderer Feature" 에 이 셰이더의 머티리얼을 넣어 사용한다.
//
//  1) 가장자리 마스크 : 화면 가운데에서의 거리(화면비 보정)로 0(가운데)~1(가장자리) 마스크
//  2) 일렁임        : 사인파로 UV 를 조금씩 밀어 화면이 물속처럼 출렁인다
//  3) 블러 + 색수차  : 황금각 나선으로 주변 픽셀을 여러 개 읽어 평균(블러)하면서,
//                    R/G/B 를 바깥 방향으로 서로 다른 거리에서 읽어 무지갯빛 테두리(색수차)
//  4) 비네트 & 안개  : 가장자리를 보랏빛으로 물들이고, 뿌연 빛을 더해 꿈속 같은 공기감
//  5) 보케 빛망울    : 화면을 칸으로 나눠 칸마다 동그란 빛망울을 띄우고 천천히 위로 흘린다
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/DreamyScreenFilter"
{
    Properties
    {
        _Intensity ("Intensity", Range(0, 1)) = 1

        [Header(Edge Mask)]
        _MaskRadius ("Clear Center Radius", Range(0, 1)) = 0.3
        _MaskSoftness ("Mask Softness", Range(0.01, 1)) = 0.55

        [Header(Wave)]
        _WaveAmount ("Wave Amount", Range(0, 0.02)) = 0.004
        _WaveFrequency ("Wave Frequency", Float) = 9
        _WaveSpeed ("Wave Speed", Float) = 1.2

        [Header(Blur and Chromatic Aberration)]
        _BlurRadius ("Blur Radius", Range(0, 0.04)) = 0.008
        _ChromaticAmount ("Chromatic Amount", Range(0, 0.03)) = 0.008

        [Header(Vignette and Haze)]
        _VignetteColor ("Vignette Tint", Color) = (0.55, 0.3, 0.8, 1)
        _VignetteStrength ("Vignette Strength", Range(0, 1)) = 0.6
        _HazeColor ("Haze Color", Color) = (0.9, 0.7, 1.0, 1)
        _HazeStrength ("Haze Strength", Range(0, 1)) = 0.05

        [Header(Bokeh)]
        [HDR] _BokehColor ("Bokeh Color", Color) = (1.2, 0.9, 1.5, 1)
        _BokehStrength ("Bokeh Strength", Range(0, 2)) = 0.35
        _BokehDensity ("Bokeh Density", Float) = 5
        _BokehSpeed ("Bokeh Rise Speed", Float) = 0.03
    }

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" "RenderType" = "Opaque" }
        ZWrite Off
        ZTest Always
        Cull Off
        Blend Off

        Pass
        {
            Name "DreamyScreenFilter"

            HLSLPROGRAM
            #pragma vertex Vert          // Blit.hlsl 의 전체 화면 삼각형 정점 셰이더
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half  _Intensity;
                half  _MaskRadius;
                half  _MaskSoftness;
                float _WaveAmount;
                float _WaveFrequency;
                float _WaveSpeed;
                float _BlurRadius;
                float _ChromaticAmount;
                half4 _VignetteColor;
                half  _VignetteStrength;
                half4 _HazeColor;
                half  _HazeStrength;
                half4 _BokehColor;
                half  _BokehStrength;
                float _BokehDensity;
                float _BokehSpeed;
            CBUFFER_END

            #define BLUR_SAMPLES 12
            #define GOLDEN_ANGLE 2.39996

            float2 Hash22(float2 p)
            {
                float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
                p3 += dot(p3, p3.yzx + 33.33);
                return frac((p3.xx + p3.yz) * p3.zy);
            }

            half3 SampleScene(float2 uv)
            {
                return SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv).rgb;
            }

            // 보케: 칸마다 하나의 동그란 빛망울, 위로 천천히 떠오르며 깜빡인다
            half Bokeh(float2 uv, float aspect, float t)
            {
                float2 p    = float2(uv.x * aspect, uv.y - t * _BokehSpeed) * _BokehDensity;
                float2 cell = floor(p);
                float2 f    = frac(p);
                float2 rnd  = Hash22(cell);
                float  size = 0.08 + 0.17 * rnd.y;                          // 칸마다 다른 크기
                float2 ctr  = size + rnd.yx * (1.0 - 2.0 * size);           // 원이 칸 밖으로 나가 잘리지 않는 범위 안에서 위치
                float  d    = length(f - ctr);
                float  disc = 1.0 - smoothstep(size * 0.7, size, d);        // 가장자리가 부드러운 원
                float  rim  = smoothstep(size * 0.5, size * 0.95, d) * disc; // 테두리가 조금 더 밝은 렌즈 보케 느낌
                float  blink = 0.5 + 0.5 * sin(t * (0.8 + rnd.x * 1.5) + rnd.y * 6.2832);
                float  exist = step(0.6, rnd.x);                             // 40% 정도의 칸에만
                return (disc * 0.35 + rim * 0.65) * blink * exist;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float2 uv     = input.texcoord;
                float  t      = _Time.y;
                float  aspect = _ScreenParams.x / _ScreenParams.y;

                // ── 1. 가장자리 마스크 (화면비 보정 → 타원이 아닌 원형) ─────────
                float2 centered = uv - 0.5;
                float  dist     = length(float2(centered.x * aspect, centered.y));
                float  mask     = smoothstep(_MaskRadius, _MaskRadius + _MaskSoftness, dist) * _Intensity;

                // ── 2. 일렁임: 가운데도 아주 약하게, 가장자리는 강하게 ──────────
                float2 wave = float2(sin(uv.y * _WaveFrequency + t * _WaveSpeed),
                                     cos(uv.x * _WaveFrequency * 0.8 + t * _WaveSpeed * 1.3));
                float2 baseUV = uv + wave * _WaveAmount * (0.25 + 0.75 * mask) * _Intensity;

                // ── 3. 블러 + 색수차 ──────────────────────────────────────────
                float2 caOffset = centered * _ChromaticAmount * mask;      // 바깥 방향으로 벌어진다
                float  radius   = _BlurRadius * mask;

                half3 color = 0;
                [unroll] for (int k = 0; k < BLUR_SAMPLES; k++)
                {
                    // 황금각 나선: 샘플이 원 안에 고르게 퍼지도록 각도는 황금각씩, 반지름은 sqrt 로 증가
                    float  a   = k * GOLDEN_ANGLE;
                    float  r   = sqrt((k + 0.5) / BLUR_SAMPLES) * radius;
                    float2 off = float2(cos(a), sin(a)) * r;
                    off.x /= aspect;

                    float2 suv = baseUV + off;
                    color.r += SampleScene(suv + caOffset).r;
                    color.g += SampleScene(suv).g;
                    color.b += SampleScene(suv - caOffset).b;
                }
                color /= BLUR_SAMPLES;

                // ── 4. 비네트 & 안개 ─────────────────────────────────────────
                float vignette = smoothstep(0.3, 1.0, dist) * _VignetteStrength * _Intensity;
                color = lerp(color, color * _VignetteColor.rgb, vignette);
                color += _HazeColor.rgb * mask * _HazeStrength;

                // ── 5. 보케 빛망울 (가장자리 위주로) ──────────────────────────
                color += _BokehColor.rgb * Bokeh(uv, aspect, t) * mask * _BokehStrength;

                return half4(color, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
