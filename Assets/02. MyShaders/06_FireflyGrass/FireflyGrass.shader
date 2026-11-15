// ─────────────────────────────────────────────────────────────────────────────
// FireflyGrass — 바람에 물결치는 풀숲과 잎 끝의 반딧불 (URP, HLSL, 정점 변형)
//
//  메시 규칙: 풀잎마다 UV.y = 0(뿌리) ~ 1(끝), 정점 색 R = 풀잎별 난수, G = 색 변화용 난수
//
//  1) 굽힘 가중치 : UV.y² — 뿌리는 땅에 고정, 끝으로 갈수록 크게 휜다 (제곱이라 자연스러운 곡선)
//  2) 돌풍        : 월드 좌표의 2D 노이즈를 바람 방향으로 흘려 보낸다 → 풀밭 위로 바람 물결이 지나간다
//  3) 팔랑임      : 풀잎마다 위상이 다른 빠른 사인파를 더해 잎이 제각각 떨린다
//  4) 길이 보정   : 옆으로 휜 만큼 끝을 아래로 내려 풀잎이 늘어나 보이지 않게 한다
//  5) 색          : 뿌리→끝 그라데이션, 돌풍이 지나가는 곳은 살짝 밝게(바람에 눕는 잎이 빛을 받는 느낌)
//  6) 반딧불      : 일부 풀잎(난수로 선택)의 끝이 각자 다른 박자로 깜빡이며 빛난다
//
//  * 정점을 움직이는 셰이더는 깊이/법선 패스에도 같은 변형을 적용해야
//    SSAO·깊이 텍스처가 실제 보이는 모양과 어긋나지 않는다.
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/FireflyGrass"
{
    Properties
    {
        [Header(Color)]
        _BottomColor ("Root Color", Color) = (0.06, 0.2, 0.08, 1)
        _TipColor ("Tip Color", Color) = (0.5, 0.88, 0.38, 1)
        _ColorVariation ("Color Variation", Range(0, 1)) = 0.35
        _VariationColor ("Variation Tip Color", Color) = (0.2, 0.55, 0.25, 1)
        [HDR] _TipGlowColor ("Tip Glow Color", Color) = (0.35, 0.85, 0.4, 1)
        _TipGlow ("Tip Glow", Range(0, 2)) = 0.35

        [Header(Wind)]
        _WindDirection ("Wind Direction (XZ)", Vector) = (1, 0, 0.4, 0)
        _WindStrength ("Gust Strength", Range(0, 1)) = 0.35
        _WindScale ("Gust Scale", Float) = 0.25
        _WindSpeed ("Gust Speed", Float) = 1.2
        _FlutterAmount ("Flutter Amount", Range(0, 0.2)) = 0.05
        _FlutterSpeed ("Flutter Speed", Float) = 6
        _WindHighlight ("Gust Highlight", Range(0, 1)) = 0.3

        [Header(Fireflies)]
        [HDR] _FireflyColor ("Firefly Color", Color) = (8.0, 6.5, 2.0, 1)
        _FireflyRatio ("Firefly Ratio", Range(0, 1)) = 0.08
        _FireflySpeed ("Firefly Blink Speed", Float) = 1.5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
        }
        Cull Off   // 얇은 풀잎은 양면을 그린다

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            half4  _BottomColor;
            half4  _TipColor;
            half   _ColorVariation;
            half4  _VariationColor;
            half4  _TipGlowColor;
            half   _TipGlow;
            float4 _WindDirection;
            half   _WindStrength;
            float  _WindScale;
            float  _WindSpeed;
            half   _FlutterAmount;
            float  _FlutterSpeed;
            half   _WindHighlight;
            half4  _FireflyColor;
            half   _FireflyRatio;
            float  _FireflySpeed;
        CBUFFER_END

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS   : NORMAL;
            float2 uv         : TEXCOORD0;
            half4  color      : COLOR;
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float3 positionWS : TEXCOORD0;
            float3 normalWS   : TEXCOORD1;
            float2 uv         : TEXCOORD2;
            half4  color      : TEXCOORD3;
            float  gust       : TEXCOORD4;
        };

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
            return lerp(lerp(Hash21(i), Hash21(i + float2(1, 0)), u.x),
                        lerp(Hash21(i + float2(0, 1)), Hash21(i + float2(1, 1)), u.x), u.y);
        }

        // 모든 패스가 공유하는 바람 정점 변형
        Varyings WindVert(Attributes v)
        {
            Varyings o;
            float3 posWS = TransformObjectToWorld(v.positionOS.xyz);
            float2 windDir = normalize(_WindDirection.xz);
            float  t = _Time.y;

            // 1. 굽힘 가중치
            float bend = v.uv.y * v.uv.y;

            // 2. 돌풍: 바람 방향으로 흘러가는 큰 노이즈 (0~1 → 대부분 한 방향으로 눕고 세기만 변함)
            float gust = ValueNoise2(posWS.xz * _WindScale - windDir * t * _WindSpeed);
            gust = smoothstep(0.2, 0.9, gust);

            // 3. 팔랑임: 풀잎 난수(정점 색 R)로 위상을 달리한 빠른 흔들림
            float flutter = sin(t * _FlutterSpeed + v.color.r * 30.0) * _FlutterAmount;

            float2 sway = windDir * (gust * _WindStrength + flutter + 0.05);
            posWS.xz += sway * bend;
            // 4. 길이 보정: 옆으로 간 거리만큼 끝을 조금 내린다
            posWS.y  -= length(sway) * bend * 0.5;

            o.positionWS = posWS;
            o.positionCS = TransformWorldToHClip(posWS);
            // 얇은 잎의 법선은 위쪽으로 기울여 부드럽게 (풀밭 전체가 한 덩어리처럼 조명을 받게)
            float3 n = TransformObjectToWorldNormal(v.normalOS);
            o.normalWS = normalize(lerp(n, float3(0, 1, 0), 0.6));
            o.uv    = v.uv;
            o.color = v.color;
            o.gust  = gust;
            return o;
        }
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex WindVert
            #pragma fragment Frag

            half4 Frag(Varyings i) : SV_Target
            {
                float h = i.uv.y;

                // 5. 색: 뿌리 → 끝, 풀잎마다 끝 색을 조금 다르게
                half3 tip = lerp(_TipColor.rgb, _VariationColor.rgb, step(1.0 - _ColorVariation, i.color.g) * i.color.g);
                half3 albedo = lerp(_BottomColor.rgb, tip, smoothstep(0.0, 1.0, h));

                float3 N = normalize(i.normalWS);
                Light mainLight = GetMainLight();
                half halfLambert = dot(N, mainLight.direction) * 0.5 + 0.5;
                half3 color = albedo * (halfLambert * mainLight.color + SampleSH(N));

                // 돌풍이 지나가는 곳은 끝이 밝아진다
                color += tip * i.gust * h * _WindHighlight;

                // 잎 끝 은은한 발광
                color += _TipGlowColor.rgb * smoothstep(0.6, 1.0, h) * _TipGlow;

                // 6. 반딧불: 난수가 (1 - 비율) 보다 큰 풀잎만, 위쪽 절반이 끝으로 갈수록 밝게 깜빡인다
                float isFirefly = step(1.0 - _FireflyRatio, frac(i.color.r * 7.31));
                float blink = pow(saturate(sin(_Time.y * _FireflySpeed * (0.6 + i.color.g) + i.color.r * 50.0) * 0.5 + 0.5), 2.0);
                float tipMask = smoothstep(0.5, 1.0, h);
                color += _FireflyColor.rgb * isFirefly * blink * tipMask * tipMask;

                return half4(color, 1.0);
            }
            ENDHLSL
        }

        // 깊이 텍스처용 (물가 거품 등 깊이를 읽는 효과와 SSAO 가 흔들리는 풀 모양을 따라가도록)
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On
            ColorMask R

            HLSLPROGRAM
            #pragma vertex WindVert
            #pragma fragment FragDepth
            half FragDepth(Varyings i) : SV_Target { return i.positionCS.z; }
            ENDHLSL
        }

        // SSAO 가 쓰는 깊이 + 법선
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }
            ZWrite On

            HLSLPROGRAM
            #pragma vertex WindVert
            #pragma fragment FragDepthNormals
            half4 FragDepthNormals(Varyings i) : SV_Target
            {
                return half4(NormalizeNormalPerPixel(i.normalWS), 0.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
