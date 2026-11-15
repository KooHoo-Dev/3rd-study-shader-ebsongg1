// ─────────────────────────────────────────────────────────────────────────────
// SpiritDissolve — 반투명한 정령의 몸이 빛가루가 되어 흩어지는 셰이더 (URP, HLSL)
//
//  1) 몸   : 반투명 기본색 + 하프 램버트 조명(부드러운 음영)
//  2) 림   : 프레넬 — 시선과 법선이 비스듬할수록 가장자리가 빛난다
//  3) 흐름 : 위로 흐르는 3D 노이즈로 몸 안에 기운이 흐르는 느낌
//  4) 디졸브: 노이즈 + 높이 그라데이션 값을 임계값과 비교해 clip(),
//            경계는 두 가지 색 그라데이션으로 타오르고 반짝이 가루가 튄다
//
//  * 셰이더볼처럼 여러 파트로 나뉜 메시도 무늬가 이어지도록 노이즈를 월드 좌표로 계산한다.
//  * 사라진 구멍으로 안쪽 면이 보이도록 뒷면 패스(Cull Front)와 앞면 패스(Cull Back)를 나눠 그린다.
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/SpiritDissolve"
{
    Properties
    {
        [Header(Body)]
        _BaseColor ("Body Color", Color) = (0.45, 0.55, 1.0, 1)
        _BodyAlpha ("Body Alpha", Range(0, 1)) = 0.45
        _BackfaceDim ("Backface Dim", Range(0, 1)) = 0.5

        [Header(Rim Fresnel)]
        [HDR] _RimColor ("Rim Color", Color) = (0.6, 0.9, 2.5, 1)
        _RimPower ("Rim Power", Range(0.5, 8)) = 2.5

        [Header(Inner Flow)]
        [HDR] _FlowColor ("Flow Color", Color) = (0.9, 0.5, 2.0, 1)
        _FlowScale ("Flow Scale", Float) = 3
        _FlowSpeed ("Flow Speed", Float) = 0.4
        _FlowStrength ("Flow Strength", Range(0, 2)) = 0.7

        [Header(Dissolve)]
        _DissolveAmount ("Dissolve Amount", Range(0, 1)) = 0.35
        [ToggleUI] _AutoDissolve ("Auto Dissolve (Ping-Pong)", Float) = 0
        _AutoSpeed ("Auto Speed", Float) = 0.15
        _NoiseScale ("Noise Scale", Float) = 4
        _HeightInfluence ("Height Influence", Range(0, 1)) = 0.4
        _HeightBottom ("Height Bottom (World Y)", Float) = 0
        _HeightTop ("Height Top (World Y)", Float) = 2

        [Header(Dissolve Edge)]
        _EdgeWidth ("Edge Width", Range(0.005, 0.3)) = 0.08
        [HDR] _EdgeColorHot ("Edge Color (Burn Line)", Color) = (2.5, 2.0, 4.0, 1)
        [HDR] _EdgeColorCool ("Edge Color (Fade)", Color) = (0.4, 0.6, 4.0, 1)
        _SparkleDensity ("Sparkle Density", Float) = 60
        _SparkleStrength ("Sparkle Strength", Range(0, 5)) = 2.5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Transparent"
            "Queue" = "Transparent"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            half4  _BaseColor;
            half   _BodyAlpha;
            half   _BackfaceDim;
            half4  _RimColor;
            half   _RimPower;
            half4  _FlowColor;
            float  _FlowScale;
            float  _FlowSpeed;
            half   _FlowStrength;
            half   _DissolveAmount;
            half   _AutoDissolve;
            float  _AutoSpeed;
            float  _NoiseScale;
            half   _HeightInfluence;
            float  _HeightBottom;
            float  _HeightTop;
            half   _EdgeWidth;
            half4  _EdgeColorHot;
            half4  _EdgeColorCool;
            float  _SparkleDensity;
            half   _SparkleStrength;
        CBUFFER_END

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS   : NORMAL;
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float3 positionWS : TEXCOORD0;
            float3 normalWS   : TEXCOORD1;
        };

        // ── 해시 & 3D 값 노이즈 ──────────────────────────────────────────────
        // 정수 격자 좌표 하나 → 0~1 사이의 의사 난수
        float Hash31(float3 p)
        {
            p = frac(p * 0.1031);
            p += dot(p, p.zyx + 31.32);
            return frac((p.x + p.y) * p.z);
        }

        // 격자 8개 꼭짓점의 난수를 부드럽게(smoothstep 곡선) 보간한다
        float ValueNoise(float3 p)
        {
            float3 i = floor(p);
            float3 f = frac(p);
            float3 u = f * f * (3.0 - 2.0 * f);

            float n000 = Hash31(i + float3(0, 0, 0));
            float n100 = Hash31(i + float3(1, 0, 0));
            float n010 = Hash31(i + float3(0, 1, 0));
            float n110 = Hash31(i + float3(1, 1, 0));
            float n001 = Hash31(i + float3(0, 0, 1));
            float n101 = Hash31(i + float3(1, 0, 1));
            float n011 = Hash31(i + float3(0, 1, 1));
            float n111 = Hash31(i + float3(1, 1, 1));

            float nx00 = lerp(n000, n100, u.x);
            float nx10 = lerp(n010, n110, u.x);
            float nx01 = lerp(n001, n101, u.x);
            float nx11 = lerp(n011, n111, u.x);
            return lerp(lerp(nx00, nx10, u.y), lerp(nx01, nx11, u.y), u.z);
        }

        // 프랙탈 노이즈: 주파수 2배, 세기 절반인 노이즈를 4겹 더해 자연스러운 무늬를 만든다
        float Fbm(float3 p)
        {
            float v = 0.0;
            float a = 0.5;
            [unroll] for (int k = 0; k < 4; k++)
            {
                v += a * ValueNoise(p);
                p = p * 2.03 + 17.1;
                a *= 0.5;
            }
            return v / 0.9375; // 0~1 로 정규화
        }

        Varyings Vert(Attributes v)
        {
            Varyings o;
            VertexPositionInputs pos = GetVertexPositionInputs(v.positionOS.xyz);
            o.positionCS = pos.positionCS;
            o.positionWS = pos.positionWS;
            o.normalWS   = TransformObjectToWorldNormal(v.normalOS);
            return o;
        }

        half4 Frag(Varyings i, bool isFrontFace)
        {
            float3 posWS = i.positionWS;

            // ── 1. 디졸브 값 계산 ───────────────────────────────────────────
            // 진행값: 직접 지정하거나, Auto 를 켜면 시간에 따라 0→1→0 왕복
            float progress = (_AutoDissolve > 0.5)
                ? sin(_Time.y * _AutoSpeed * TWO_PI) * 0.5 + 0.5
                : _DissolveAmount;

            float noise  = Fbm(posWS * _NoiseScale);
            // 위쪽일수록 값이 작아져 먼저 사라진다 → 머리부터 하늘로 흩어지는 연출
            float height = saturate((posWS.y - _HeightBottom) / max(_HeightTop - _HeightBottom, 1e-3));
            float d      = lerp(noise, 1.0 - height, _HeightInfluence);

            // 진행값 0 일 때는 경계까지 완전히 숨기고, 1 일 때는 전부 사라지도록 범위를 넓힌다
            float threshold = progress * (1.0 + _EdgeWidth) - _EdgeWidth;
            clip(d - threshold);

            // 경계 띠: 임계값 바로 위(0)~EdgeWidth 만큼 떨어진 곳(1)
            float edgeT = saturate((d - threshold) / _EdgeWidth);
            float edge  = 1.0 - smoothstep(0.0, 1.0, edgeT);
            half3 edgeColor = lerp(_EdgeColorCool.rgb, _EdgeColorHot.rgb, edge * edge);

            // 반짝이 가루: 경계 근처의 작은 격자 칸 중 일부에 동그란 빛 알갱이가 빠르게 깜빡인다
            float sparkleBand = 1.0 - saturate((d - threshold) / (_EdgeWidth * 3.0));
            float3 sparkleP    = posWS * _SparkleDensity;
            float3 sparkleCell = floor(sparkleP);
            float  blink       = floor(_Time.y * 8.0);
            float  sparkleOn   = step(0.9, Hash31(sparkleCell + blink));
            float3 sparkleCtr  = float3(Hash31(sparkleCell + 1.3), Hash31(sparkleCell + 2.7), Hash31(sparkleCell + 4.1)) * 0.5 + 0.25;
            float  sparkleDot  = 1.0 - smoothstep(0.0, 0.3, length(frac(sparkleP) - sparkleCtr));
            float sparkle = sparkleOn * sparkleDot * sparkleBand * step(0.001, progress) * _SparkleStrength;

            // ── 2. 조명 & 림 ────────────────────────────────────────────────
            float3 N = normalize(i.normalWS);
            N = isFrontFace ? N : -N;                       // 뒷면은 법선을 뒤집는다
            float3 V = GetWorldSpaceNormalizeViewDir(posWS);

            Light mainLight = GetMainLight();
            half halfLambert = dot(N, mainLight.direction) * 0.5 + 0.5;   // 0~1, 그림자 쪽도 너무 어둡지 않게
            half3 diffuse = _BaseColor.rgb * (halfLambert * mainLight.color + SampleSH(N));

            half fresnel = pow(1.0 - saturate(dot(N, V)), _RimPower);
            half3 rim = fresnel * _RimColor.rgb;

            // ── 3. 몸 안의 흐름 ────────────────────────────────────────────
            float flowNoise = Fbm(posWS * _FlowScale + float3(0, -_Time.y * _FlowSpeed, 0));
            half flow = smoothstep(0.5, 0.8, flowNoise) * _FlowStrength;

            // ── 4. 합성 ────────────────────────────────────────────────────
            half3 color = diffuse + rim + flow * _FlowColor.rgb;
            color = lerp(color, edgeColor, edge);            // 경계는 경계색으로 덮는다
            color += sparkle * _EdgeColorHot.rgb;

            half alpha = saturate(_BodyAlpha + fresnel + flow * 0.5 + edge + sparkle);

            if (!isFrontFace)
            {
                color *= _BackfaceDim;                        // 안쪽 면은 조금 어둡게 → 깊이감
            }
            return half4(color, alpha);
        }
        ENDHLSL

        // 패스 1: 안쪽(뒷면) 먼저 — 디졸브 구멍 사이로 보이는 몸 안쪽
        Pass
        {
            Name "Backface"
            Tags { "LightMode" = "SRPDefaultUnlit" }
            Cull Front
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragBack
            half4 FragBack(Varyings i) : SV_Target { return Frag(i, false); }
            ENDHLSL
        }

        // 패스 2: 바깥(앞면)
        Pass
        {
            Name "Frontface"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            ZWrite On
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragFront
            half4 FragFront(Varyings i) : SV_Target { return Frag(i, true); }
            ENDHLSL
        }
    }
    FallBack Off
}
