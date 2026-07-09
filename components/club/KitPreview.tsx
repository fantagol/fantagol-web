type KitPreviewProps = {
  primary?: string;
  secondary?: string;
  third?: string;
  template?: string;
  logoMode?: string;
  crestPosition?: string;
  starsCount?: number;
  hasScudetto?: boolean;
};

export default function KitPreview({
  primary = "#FFFFFF",
  secondary = "#111417",
  third = "#A6E824",
  template = "solid",
  logoMode = "center_horizontal",
  crestPosition = "left_chest",
  starsCount = 0,
  hasScudetto = false,
}: KitPreviewProps) {
  const stars = "★".repeat(Math.min(starsCount, 5));

  return (
    <svg viewBox="0 0 300 340" className="mx-auto h-80 w-64">
      <defs>
        <linearGradient id="kit-shadow" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0.18" />
          <stop offset="55%" stopColor="#000000" stopOpacity="0" />
          <stop offset="100%" stopColor="#000000" stopOpacity="0.16" />
        </linearGradient>

        <clipPath id="shirt-clip">
          <path d="M82 46 L116 24 H184 L218 46 L258 70 Q267 77 262 90 L236 136 Q232 144 220 140 L212 132 L218 242 Q218 252 208 252 H92 Q82 252 82 242 L88 132 L80 140 Q68 144 64 136 L38 90 Q33 77 42 70 Z" />
        </clipPath>
      </defs>

      <g transform="translate(150 170) scale(1.12) translate(-150 -170)">
        <path
          d="M82 46 L116 24 H184 L218 46 L258 70 Q267 77 262 90 L236 136 Q232 144 220 140 L212 132 L218 242 Q218 252 208 252 H92 Q82 252 82 242 L88 132 L80 140 Q68 144 64 136 L38 90 Q33 77 42 70 Z"
          fill={primary}
          stroke={secondary}
          strokeWidth="7"
          strokeLinejoin="round"
        />

        <g clipPath="url(#shirt-clip)">
          {(template === "center_band" || template === "central_pole") && (
            <rect x="116" y="28" width="68" height="246" fill={secondary} opacity="0.9" />
          )}

          {(template === "vertical_stripes" || template === "vertical_3") && (
            <>
              <rect x="66" y="20" width="34" height="256" fill={secondary} opacity="0.9" />
              <rect x="133" y="20" width="34" height="256" fill={secondary} opacity="0.9" />
              <rect x="200" y="20" width="34" height="256" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "vertical_5" && (
            <>
              <rect x="58" y="20" width="24" height="256" fill={secondary} opacity="0.9" />
              <rect x="106" y="20" width="24" height="256" fill={secondary} opacity="0.9" />
              <rect x="154" y="20" width="24" height="256" fill={secondary} opacity="0.9" />
              <rect x="202" y="20" width="24" height="256" fill={secondary} opacity="0.9" />
              <rect x="250" y="20" width="24" height="256" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "thin_stripes" && (
            <>
              <rect x="72" y="20" width="14" height="256" fill={secondary} opacity="0.9" />
              <rect x="108" y="20" width="14" height="256" fill={secondary} opacity="0.9" />
              <rect x="144" y="20" width="14" height="256" fill={secondary} opacity="0.9" />
              <rect x="180" y="20" width="14" height="256" fill={secondary} opacity="0.9" />
              <rect x="216" y="20" width="14" height="256" fill={secondary} opacity="0.9" />
            </>
          )}

          {(template === "horizontal_stripes" || template === "horizontal_3") && (
            <>
              <rect x="45" y="92" width="210" height="22" fill={secondary} opacity="0.9" />
              <rect x="45" y="150" width="210" height="22" fill={secondary} opacity="0.9" />
              <rect x="45" y="208" width="210" height="22" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "horizontal_band" && (
            <rect x="45" y="128" width="210" height="50" fill={secondary} opacity="0.9" />
          )}

          {template === "chest_panel" && (
            <path d="M70 92 H230 V164 H70 Z" fill={secondary} opacity="0.9" />
          )}

          {template === "diagonal" && (
            <path d="M50 250 L218 42 L250 66 L82 276 Z" fill={secondary} opacity="0.9" />
          )}

          {template === "diagonal_reverse" && (
            <path d="M250 250 L82 42 L50 66 L218 276 Z" fill={secondary} opacity="0.9" />
          )}

          {template === "sash" && (
            <path d="M44 122 L72 98 L256 214 L228 246 Z" fill={secondary} opacity="0.9" />
          )}

          {template === "sleeves" && (
            <>
              <path d="M42 70 L82 46 L88 132 L80 140 L38 90 Q33 77 42 70 Z" fill={secondary} opacity="0.9" />
              <path d="M218 46 L258 70 Q267 77 262 90 L220 140 L212 132 Z" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "shoulders" && (
            <>
              <path d="M42 70 L82 46 L116 24 H150 V78 Q105 72 64 104 L38 90 Q33 77 42 70 Z" fill={secondary} opacity="0.9" />
              <path d="M150 24 H184 L218 46 L258 70 Q267 77 262 90 L236 104 Q195 72 150 78 Z" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "cross" && (
            <>
              <rect x="128" y="28" width="44" height="246" fill={secondary} opacity="0.9" />
              <rect x="45" y="132" width="210" height="44" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "quarters" && (
            <>
              <rect x="45" y="28" width="105" height="122" fill={secondary} opacity="0.9" />
              <rect x="150" y="150" width="105" height="160" fill={secondary} opacity="0.9" />
            </>
          )}

          {template === "split" && (
            <rect x="150" y="20" width="110" height="256" fill={secondary} opacity="0.9" />
          )}

          {template === "third_details" && (
            <>
              <rect x="116" y="28" width="68" height="246" fill={secondary} opacity="0.9" />
              <rect x="138" y="28" width="24" height="246" fill={third} opacity="0.9" />
            </>
          )}

          <path d="M119 24 H181 L170 58 H130 Z" fill={third} opacity="0.96" />
          <path d="M94 45 Q150 70 206 45" fill="none" stroke={third} strokeWidth="4" opacity="0.75" />
          <path d="M82 46 L88 132" fill="none" stroke={secondary} strokeWidth="2" opacity="0.18" />
          <path d="M218 46 L212 132" fill="none" stroke={secondary} strokeWidth="2" opacity="0.18" />
          <path d="M0 0 H300 V340 H0 Z" fill="url(#kit-shadow)" />
        </g>

        <path
          d="M119 24 H181 L170 58 H130 Z"
          fill="none"
          stroke={secondary}
          strokeWidth="5"
          strokeLinejoin="round"
          opacity="0.85"
        />

        {stars && (
          <text
            x="150"
            y="84"
            textAnchor="middle"
            fontSize="18"
            fontWeight="900"
            fill={third}
          >
            {stars}
          </text>
        )}

        {hasScudetto && (
          <g transform="translate(141 75) scale(0.46)" opacity="0.92">
            <defs>
              <clipPath id="scudetto-tricolore-clip">
                <path d="M0 0 H36 V34 Q18 48 0 34 Z" />
              </clipPath>

              <linearGradient id="scudetto-gold" x1="0" x2="1" y1="0" y2="1">
                <stop offset="0%" stopColor="#fff3a3" />
                <stop offset="42%" stopColor="#d4a83a" />
                <stop offset="100%" stopColor="#7a5313" />
              </linearGradient>

              <linearGradient id="scudetto-gloss" x1="0" x2="0" y1="0" y2="1">
                <stop offset="0%" stopColor="#ffffff" stopOpacity="0.35" />
                <stop offset="45%" stopColor="#ffffff" stopOpacity="0.08" />
                <stop offset="100%" stopColor="#000000" stopOpacity="0.18" />
              </linearGradient>
            </defs>

            <path d="M-3 -3 H39 V36 Q18 53 -3 36 Z" fill="#050505" opacity="0.5" />
            <path d="M-1.5 -1.5 H37.5 V35 Q18 51 -1.5 35 Z" fill="url(#scudetto-gold)" />

            <g clipPath="url(#scudetto-tricolore-clip)">
              <rect x="0" y="0" width="12" height="48" fill="#11823b" />
              <rect x="12" y="0" width="12" height="48" fill="#f4f4ef" />
              <rect x="24" y="0" width="12" height="48" fill="#d61f2c" />
              <path d="M0 0 H36 V48 H0 Z" fill="url(#scudetto-gloss)" />
            </g>

            <path
              d="M0 0 H36 V34 Q18 48 0 34 Z"
              fill="none"
              stroke="#f4d36b"
              strokeWidth="2"
              strokeLinejoin="round"
            />

            <path
              d="M4 4 H32 V31 Q18 42 4 31 Z"
              fill="none"
              stroke="#ffffff"
              strokeOpacity="0.22"
              strokeWidth="1"
              strokeLinejoin="round"
            />
          </g>
        )}

        {logoMode === "center_horizontal" && (
          <>
            <image
              href="/logo/logo-ball-clean.png"
              x={crestPosition === "right_chest" ? "183" : "93"}
              y="72"
              width="24"
              height="24"
              opacity="0.78"
              preserveAspectRatio="xMidYMid meet"
            />
            <image
              href="/logo/logo-wordmark-clean.png"
              x="33"
              y="92"
              width="232"
              height="60"
              opacity="0.78"
              preserveAspectRatio="xMidYMid meet"
            />
          </>
        )}

        {logoMode === "wordmark_only" && (
          <image
            href="/logo/logo-wordmark-clean.png"
            x="33"
            y="92"
            width="232"
            height="60"
            opacity="0.78"
            preserveAspectRatio="xMidYMid meet"
          />
        )}

        <path d="M82 240 H218 V254 Q218 262 208 262 H92 Q82 262 82 254 Z" fill={secondary} opacity="0.96" />
      </g>
    </svg>
  );
}
