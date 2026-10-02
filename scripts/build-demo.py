"""Keep the isolated demo shell in sync with the shipped registry."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
s=(root/'index.html').read_text().replace('<title>MNCS Registry · Malawi sport, connected</title>','<title>MNCS Registry · isolated demo</title>')
s=s.replace('<script src="js/config.js"></script>','<script src="js/demo.js"></script>').replace('<script src="js/vendor/supabase.js"></script>','')
s=s.replace('<script src="js/demo.js"></script>', '<script src="js/demo.js"></script>\n  <script src="js/demo-sports.js"></script>')
s=s.replace('<body class="bg-slate-50 text-slate-800 font-sans antialiased">','<body class="bg-slate-50 text-slate-800 font-sans antialiased"><div class="demo-banner">ISOLATED DEMO · fictional accounts · resets on reload · <a href="index.html">Return to live registry</a></div>')
(root/'demo.html').write_text(s)
