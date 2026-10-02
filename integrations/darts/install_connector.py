"""Run from the existing Darts source root. Copies the connector; preserves existing functions."""
from pathlib import Path
import shutil
import tomllib
source=Path(__file__).resolve().parent
root=Path.cwd()
if root==source or not (root/'index.html').is_file() or not (root/'app.js').is_file():
 raise SystemExit('Run this script from the existing Darts source folder containing index.html and app.js.')
config=root/'netlify.toml'
if config.exists():
 settings=tomllib.loads(config.read_text())
 functions=settings.get('functions',{}).get('directory',settings.get('build',{}).get('functions','netlify/functions'))
 if functions.rstrip('/') not in ['netlify/functions','./netlify/functions']:
  raise SystemExit('This addon expects netlify/functions. Adapt the function and its relative lib import to your custom directory before installing.')
for folder in ['assets','lib','netlify/functions']:
 for file in (source/folder).glob('*'):
  target=root/folder/file.name;target.parent.mkdir(parents=True,exist_ok=True)
  if target.exists() and target.read_bytes()!=file.read_bytes():
   backup=target.with_name(target.name+'.before-mncs');
   if not backup.exists():shutil.copy2(target,backup)
  shutil.copy2(file,target)
index=root/'index.html';text=index.read_text();script='<script src="assets/mncs-connect.js"></script>';css='<link rel="stylesheet" href="assets/mncs-connect.css">'
if script not in text:
 if '</body>' not in text or '</head>' not in text:raise SystemExit('The existing index must contain closing head and body tags.')
 backup=root/'index.before-mncs.html'
 if not backup.exists():shutil.copy2(index,backup)
 text=text.replace('</head>',css+'\n</head>').replace('</body>',script+'\n</body>');index.write_text(text)
print('Connector installed. Existing Darts app and results function preserved. Configure private MNCS connection settings before deployment.')
