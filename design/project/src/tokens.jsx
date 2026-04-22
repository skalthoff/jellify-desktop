// Jellify desktop — design tokens + Icon + Artwork placeholder

const JF = /*EDITMODE-BEGIN*/{
  "theme": "purple",
  "mode": "dark",
  "accent": "pink",
  "density": "roomy",
  "screen": "home",
  "rightPanel": "now-playing"
}/*EDITMODE-END*/;

// Theme presets: { bg, bgAlt, surface, primary, accent }
const THEMES = {
  purple: {
    dark: { bg:'#0C0622', bgAlt:'#140B30', surface:'rgba(126,114,175,0.08)', surface2:'rgba(126,114,175,0.14)',
      ink:'#fff', ink2:'rgba(126,114,175,1)', ink3:'rgba(126,114,175,0.65)',
      primary:'#887BFF', accent:'#CC2F71', accentHot:'#FF066F', teal:'#57E9C9',
      border:'rgba(126,114,175,0.18)', borderStrong:'rgba(126,114,175,0.35)',
      rowHover:'rgba(126,114,175,0.10)' },
    light: { bg:'#F7F4FF', bgAlt:'#EFE9FF', surface:'rgba(75,15,214,0.05)', surface2:'rgba(75,15,214,0.09)',
      ink:'#100538', ink2:'#4A3D7A', ink3:'#7B6FA8',
      primary:'#4B0FD6', accent:'#B30077', accentHot:'#FF066F', teal:'#10AF8D',
      border:'rgba(75,15,214,0.12)', borderStrong:'rgba(75,15,214,0.22)',
      rowHover:'rgba(75,15,214,0.06)' },
    oled: { bg:'#000', bgAlt:'#0a0612', surface:'rgba(126,114,175,0.08)', surface2:'rgba(126,114,175,0.14)',
      ink:'#fff', ink2:'rgba(126,114,175,1)', ink3:'rgba(126,114,175,0.65)',
      primary:'#887BFF', accent:'#CC2F71', accentHot:'#FF066F', teal:'#57E9C9',
      border:'rgba(126,114,175,0.15)', borderStrong:'rgba(126,114,175,0.3)',
      rowHover:'rgba(126,114,175,0.08)' },
  },
  ocean: {
    dark: { bg:'#041025', bgAlt:'#0A1A38', surface:'rgba(75,125,215,0.10)', surface2:'rgba(75,125,215,0.16)',
      ink:'#fff', ink2:'rgba(138,170,220,1)', ink3:'rgba(138,170,220,0.65)',
      primary:'#4B7DD7', accent:'#57E9C9', accentHot:'#22E4C8', teal:'#57E9C9',
      border:'rgba(75,125,215,0.20)', borderStrong:'rgba(75,125,215,0.38)',
      rowHover:'rgba(75,125,215,0.12)' },
  },
  forest: {
    dark: { bg:'#081A14', bgAlt:'#0E2820', surface:'rgba(87,233,201,0.08)', surface2:'rgba(87,233,201,0.14)',
      ink:'#fff', ink2:'rgba(137,199,175,1)', ink3:'rgba(137,199,175,0.65)',
      primary:'#10AF8D', accent:'#FFB86B', accentHot:'#FF9A3C', teal:'#57E9C9',
      border:'rgba(87,233,201,0.15)', borderStrong:'rgba(87,233,201,0.3)',
      rowHover:'rgba(87,233,201,0.08)' },
  },
  sunset: {
    dark: { bg:'#24060F', bgAlt:'#380B1C', surface:'rgba(255,102,37,0.08)', surface2:'rgba(255,102,37,0.14)',
      ink:'#fff', ink2:'rgba(255,160,140,1)', ink3:'rgba(255,160,140,0.65)',
      primary:'#FF6625', accent:'#FFD166', accentHot:'#FF066F', teal:'#FFD166',
      border:'rgba(255,102,37,0.15)', borderStrong:'rgba(255,102,37,0.3)',
      rowHover:'rgba(255,102,37,0.08)' },
  },
  peanut: {
    dark: { bg:'#1C140A', bgAlt:'#2B1F12', surface:'rgba(212,163,96,0.08)', surface2:'rgba(212,163,96,0.14)',
      ink:'#fff', ink2:'rgba(212,180,140,1)', ink3:'rgba(212,180,140,0.65)',
      primary:'#D4A360', accent:'#FF066F', accentHot:'#FF066F', teal:'#57E9C9',
      border:'rgba(212,163,96,0.15)', borderStrong:'rgba(212,163,96,0.3)',
      rowHover:'rgba(212,163,96,0.08)' },
  },
};

function resolveTheme(themeName, modeName) {
  const theme = THEMES[themeName] || THEMES.purple;
  return theme[modeName] || theme.dark || theme.light;
}

const FONT_FAMILY = "'Figtree', ui-sans-serif, system-ui, -apple-system, sans-serif";

// ─── Icon ──────────────────────────────────────────────────────────────
function Icon({ name, size = 18, color = 'currentColor', fill = false, style, strokeWidth = 2 }) {
  const s = { width:size, height:size, display:'inline-block', verticalAlign:'middle', flexShrink:0, ...style };
  const common = { width:size, height:size, viewBox:'0 0 24 24',
    fill: fill ? color : 'none', stroke: color, strokeWidth, strokeLinecap:'round', strokeLinejoin:'round', style: s };
  switch (name) {
    case 'home': return <svg {...common}><path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-7h-6v7H4a1 1 0 0 1-1-1z"/></svg>;
    case 'library': return <svg {...common}><path d="M8 5v14"/><path d="M5 5h3l4 14h-3z"/><path d="M14 5h3l4 14h-3z"/></svg>;
    case 'search': return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>;
    case 'compass': return <svg {...common}><circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5.5-5.5 2 2-5.5z"/></svg>;
    case 'settings': return <svg {...common}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>;
    case 'heart': return <svg {...common}><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 1 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z"/></svg>;
    case 'download': return <svg {...common}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/></svg>;
    case 'check-circle': return <svg {...common}><circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/></svg>;
    case 'dots': return <svg {...common}><circle cx="5" cy="12" r="1.3" fill={color}/><circle cx="12" cy="12" r="1.3" fill={color}/><circle cx="19" cy="12" r="1.3" fill={color}/></svg>;
    case 'dots-v': return <svg {...common}><circle cx="12" cy="5" r="1.3" fill={color}/><circle cx="12" cy="12" r="1.3" fill={color}/><circle cx="12" cy="19" r="1.3" fill={color}/></svg>;
    case 'plus': return <svg {...common}><path d="M12 5v14M5 12h14"/></svg>;
    case 'play': return <svg {...common} fill={color} stroke="none"><path d="M7 4.5v15a1 1 0 0 0 1.5.87l13-7.5a1 1 0 0 0 0-1.74l-13-7.5A1 1 0 0 0 7 4.5z"/></svg>;
    case 'pause': return <svg {...common} fill={color} stroke="none"><rect x="6" y="4.5" width="4" height="15" rx="1"/><rect x="14" y="4.5" width="4" height="15" rx="1"/></svg>;
    case 'skip-next': return <svg {...common} fill={color} stroke="none"><path d="M5 5v14l10-7z"/><rect x="16" y="5" width="3" height="14" rx="1"/></svg>;
    case 'skip-prev': return <svg {...common} fill={color} stroke="none"><path d="M19 5v14L9 12z"/><rect x="5" y="5" width="3" height="14" rx="1"/></svg>;
    case 'shuffle': return <svg {...common}><path d="M16 3h5v5"/><path d="M4 20 21 3"/><path d="M21 16v5h-5"/><path d="m15 15 6 6"/><path d="m4 4 5 5"/></svg>;
    case 'repeat': return <svg {...common}><path d="M17 2l4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/></svg>;
    case 'queue': return <svg {...common}><path d="M3 6h13M3 12h13M3 18h9"/><path d="M19 14v8l5-4z" fill={color} stroke="none"/></svg>;
    case 'filter': return <svg {...common}><path d="M3 5h18M6 12h12M10 19h4"/></svg>;
    case 'sort': return <svg {...common}><path d="M3 6h18M6 12h12M10 18h4"/></svg>;
    case 'close': return <svg {...common}><path d="M6 6l12 12M18 6 6 18"/></svg>;
    case 'chevron-right': return <svg {...common}><path d="m9 6 6 6-6 6"/></svg>;
    case 'chevron-left': return <svg {...common}><path d="m15 6-6 6 6 6"/></svg>;
    case 'chevron-down': return <svg {...common}><path d="m6 9 6 6 6-6"/></svg>;
    case 'chevron-up': return <svg {...common}><path d="m6 15 6-6 6 6"/></svg>;
    case 'cast': return <svg {...common}><path d="M2 18a4 4 0 0 1 4 4"/><path d="M2 14a8 8 0 0 1 8 8"/><path d="M2 10a12 12 0 0 1 12 12"/><path d="M20 20v-12a2 2 0 0 0-2-2h-14"/></svg>;
    case 'mic': return <svg {...common}><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></svg>;
    case 'user': return <svg {...common}><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>;
    case 'music': return <svg {...common}><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>;
    case 'clock': return <svg {...common}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>;
    case 'album': return <svg {...common}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/></svg>;
    case 'list': return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13"/><circle cx="4" cy="6" r="1" fill={color}/><circle cx="4" cy="12" r="1" fill={color}/><circle cx="4" cy="18" r="1" fill={color}/></svg>;
    case 'grid': return <svg {...common}><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>;
    case 'volume': return <svg {...common}><path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15 9a4 4 0 0 1 0 6"/><path d="M18 6a8 8 0 0 1 0 12"/></svg>;
    case 'volume-off': return <svg {...common}><path d="M11 5 6 9H3v6h3l5 4z"/><path d="m17 9 4 6M21 9l-4 6"/></svg>;
    case 'mix': return <svg {...common}><path d="M3 12h3l3-8 4 16 3-8h5"/></svg>;
    case 'bell': return <svg {...common}><path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10 21a2 2 0 0 0 4 0"/></svg>;
    case 'star': return <svg {...common}><path d="m12 3 2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.8 6.2 20.9l1.1-6.5L2.6 9.8l6.5-.9z"/></svg>;
    case 'radio': return <svg {...common}><circle cx="12" cy="12" r="2"/><path d="M16.2 7.8a6 6 0 0 1 0 8.4M19 5a10 10 0 0 1 0 14M7.8 7.8a6 6 0 0 0 0 8.4M5 5a10 10 0 0 0 0 14"/></svg>;
    case 'folder': return <svg {...common}><path d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>;
    case 'fullscreen': return <svg {...common}><path d="M4 9V5a1 1 0 0 1 1-1h4M20 9V5a1 1 0 0 0-1-1h-4M4 15v4a1 1 0 0 0 1 1h4M20 15v4a1 1 0 0 1-1 1h-4"/></svg>;
    case 'minimize': return <svg {...common}><path d="M8 3v4a1 1 0 0 1-1 1H3M21 8h-4a1 1 0 0 1-1-1V3M3 16h4a1 1 0 0 1 1 1v4M16 21v-4a1 1 0 0 1 1-1h4"/></svg>;
    case 'trending': return <svg {...common}><path d="m3 17 6-6 4 4 8-8"/><path d="M14 7h7v7"/></svg>;
    case 'history': return <svg {...common}><path d="M3 3v5h5"/><path d="M3.1 13a9 9 0 1 0 1-5.3L3 8"/><path d="M12 7v5l4 2"/></svg>;
    case 'cloud': return <svg {...common}><path d="M17 8a5 5 0 0 0-9.6-1.4A4.5 4.5 0 1 0 6.5 19H17a5.5 5.5 0 0 0 0-11z"/></svg>;
    case 'server': return <svg {...common}><rect x="3" y="4" width="18" height="7" rx="1"/><rect x="3" y="13" width="18" height="7" rx="1"/><circle cx="7" cy="7.5" r="0.7" fill={color}/><circle cx="7" cy="16.5" r="0.7" fill={color}/></svg>;
    case 'sidebar': return <svg {...common}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/></svg>;
    default: return <svg {...common}><circle cx="12" cy="12" r="9"/></svg>;
  }
}

// ─── Artwork ────────────────────────────────────────────────────────────
function Artwork({ seed = 'x', size = 110, radius = 8, label, sublabel, style, onClick }) {
  const palettes = [
    ['#2B1E5C','#887BFF'], ['#4B0FD6','#FF066F'], ['#0F3D48','#57E9C9'],
    ['#3A1655','#CC2F71'], ['#1F1A4A','#4B7DD7'], ['#271055','#A96BFF'],
    ['#541A2E','#FF6625'], ['#10314F','#2FA6D9'], ['#4A2260','#ECECEC'],
    ['#223355','#887BFF'], ['#1B0A4C','#57E9C9'], ['#5B153B','#FFD166'],
    ['#0e2a25','#57E9C9'], ['#370a5b','#FFB86B'], ['#2a0f4c','#CC2F71'],
  ];
  let h = 0; for (let i=0;i<seed.length;i++) h = (h*31 + seed.charCodeAt(i)) >>> 0;
  const [a, b] = palettes[h % palettes.length];
  const angle = (h % 180);
  const rot = (h % 360);
  return (
    <div onClick={onClick} style={{
      width:size, height:size, borderRadius:radius, flexShrink:0,
      background: `linear-gradient(${angle}deg, ${a} 0%, ${b} 100%)`,
      position:'relative', overflow:'hidden',
      boxShadow:'0 6px 16px rgba(0,0,0,0.35)',
      cursor: onClick ? 'pointer' : undefined,
      ...style
    }}>
      {/* concentric rings for a "vinyl" vibe */}
      <div style={{position:'absolute', inset:'-40%', borderRadius:'50%',
        transform:`rotate(${rot}deg)`,
        border:`${Math.max(2, size*0.03)}px solid rgba(255,255,255,0.08)`}}/>
      <div style={{position:'absolute', inset:'-15%', borderRadius:'50%',
        transform:`rotate(${-rot}deg)`,
        border:`${Math.max(1, size*0.02)}px solid rgba(255,255,255,0.14)`}}/>
      <div style={{position:'absolute', inset:'10%', borderRadius:'50%',
        border:`${Math.max(1, size*0.015)}px solid rgba(255,255,255,0.08)`}}/>
      {label && <div style={{
        position:'absolute', left:size*0.08, bottom:size*0.07, right:size*0.08,
        fontFamily:FONT_FAMILY, color:'rgba(255,255,255,0.92)',
        fontSize: Math.max(9, size*0.085), fontWeight:800, letterSpacing:'-0.01em',
        textShadow:'0 2px 6px rgba(0,0,0,0.55)', lineHeight:1.1,
      }}>
        {label}
        {sublabel && <div style={{fontSize: Math.max(7, size*0.055), fontWeight:500, opacity:0.8, marginTop:2}}>{sublabel}</div>}
      </div>}
    </div>
  );
}

Object.assign(window, { JF, THEMES, resolveTheme, FONT_FAMILY, Icon, Artwork });
