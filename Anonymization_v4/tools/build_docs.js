/* ============================================================================
 * build_docs.js - render the guides in docs/ to HTML and DOCX
 * ============================================================================
 *   node tools/build_docs.js
 *
 * Markdown is the source of truth. The .html and .docx beside each .md are
 * generated, so edit only the .md and re-run this.
 *
 * Deliberately dependency-free: this repository is an Oracle/SQL*Plus package
 * and adding an npm tree to it to produce two documents would not be a fair
 * trade. It handles the Markdown subset the guides actually use - headings,
 * paragraphs, fenced code, tables, blockquotes, lists, rules, and inline
 * bold/italic/code/links - and nothing else.
 *
 * The DOCX is written by hand as OOXML: a zip of [Content_Types].xml, the two
 * relationship parts, styles.xml and document.xml. Lists use a literal bullet
 * or number rather than numbering.xml, which needs no numbering definitions to
 * be resolved by the reader and so renders identically everywhere.
 * ==========================================================================*/

'use strict';
const fs   = require('fs');
const path = require('path');
const os   = require('os');
const { execFileSync } = require('child_process');

const DOCS = path.join(__dirname, '..', 'docs');

/* ---------------------------------------------------------------- parsing --
 * One pass, line by line, into a flat list of blocks. No nesting beyond what
 * the guides use, which keeps the renderers straightforward.
 */
function parse(md) {
   const lines  = md.replace(/\r\n/g, '\n').split('\n');
   const blocks = [];
   let i = 0;

   const isTableSep = s => /^\|?[\s:|-]+\|[\s:|-]*$/.test(s) && s.includes('-');

   while (i < lines.length) {
      const line = lines[i];

      if (!line.trim()) { i++; continue; }

      // fenced code
      if (/^```/.test(line)) {
         const lang = line.slice(3).trim();
         const body = [];
         i++;
         while (i < lines.length && !/^```/.test(lines[i])) body.push(lines[i++]);
         i++;
         blocks.push({ t: 'code', lang, lines: body });
         continue;
      }

      // horizontal rule
      if (/^---+\s*$/.test(line)) { blocks.push({ t: 'hr' }); i++; continue; }

      // heading
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) { blocks.push({ t: 'h', level: h[1].length, text: h[2].trim() }); i++; continue; }

      // table - a header row followed by a separator row
      if (line.trim().startsWith('|') && i + 1 < lines.length && isTableSep(lines[i + 1])) {
         const cells = s => s.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim());
         const head  = cells(line);
         const align = cells(lines[i + 1]).map(s =>
            /^:-+:$/.test(s) ? 'center' : /-+:$/.test(s) ? 'right' : 'left');
         i += 2;
         const rows = [];
         while (i < lines.length && lines[i].trim().startsWith('|')) rows.push(cells(lines[i++]));
         blocks.push({ t: 'table', head, align, rows });
         continue;
      }

      // blockquote - collected whole, then parsed as its own document
      if (/^>\s?/.test(line)) {
         const body = [];
         while (i < lines.length && (/^>\s?/.test(lines[i]) || (body.length && !lines[i].trim()))) {
            if (!lines[i].trim()) { if (!/^>/.test(lines[i + 1] || '')) break; body.push(''); i++; continue; }
            body.push(lines[i].replace(/^>\s?/, ''));
            i++;
         }
         blocks.push({ t: 'quote', blocks: parse(body.join('\n')) });
         continue;
      }

      // list - bullet, task or ordered
      if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
         const ordered = /^\s*\d+\.\s/.test(line);
         const items   = [];
         while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
            let text = lines[i].replace(/^\s*([-*]|\d+\.)\s+/, '');
            i++;
            // continuation lines are indented and not a new item
            while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
               text += ' ' + lines[i].trim();
               i++;
            }
            items.push(text);
         }
         blocks.push({ t: 'list', ordered, items });
         continue;
      }

      // paragraph
      const para = [];
      while (i < lines.length && lines[i].trim()
             && !/^```|^---+\s*$|^#{1,6}\s|^>\s?/.test(lines[i])
             && !/^\s*([-*]|\d+\.)\s+/.test(lines[i])
             && !(lines[i].trim().startsWith('|') && isTableSep(lines[i + 1] || ''))) {
         para.push(lines[i].trim());
         i++;
      }
      if (para.length) blocks.push({ t: 'p', text: para.join(' ') });
      else i++;
   }
   return blocks;
}

/* ----------------------------------------------------------------- inline --
 * Code spans are extracted first and never re-scanned, so a ** inside `code`
 * stays literal.
 */
function inline(text) {
   // Backslash escapes are lifted out before matching and put back afterwards.
   // Without this a \* inside **bold** defeats the bold pattern and the run is
   // parsed as a stray italic - which is exactly what SQL\*Plus did.
   const held = [];
   const HOLD = String.fromCharCode(1);   // cannot occur in the source text
   text = String(text).replace(/\\([\\`*_[\]()#+\-.!|<>])/g,
                               (mm, c) => HOLD + (held.push(c) - 1) + HOLD);
   const unhold = s => held.length
      ? s.replace(new RegExp(HOLD + '(\\d+)' + HOLD, 'g'), (mm, n) => held[n])
      : s;

   const out = [];
   const re  = /(`[^`]+`)|(\[[^\]]+\]\([^)]*\))|(\*\*[^*]+\*\*)|(\*[^*]+\*)/g;
   let last = 0, m;
   const plain = s => { if (s) out.push({ text: s }); };

   while ((m = re.exec(text)) !== null) {
      plain(text.slice(last, m.index));
      const tok = m[0];
      if (tok.startsWith('`'))       out.push({ text: tok.slice(1, -1), code: true });
      else if (tok.startsWith('[')) {
         const link = tok.match(/^\[([^\]]+)\]\(([^)]*)\)$/);
         out.push({ text: link[1], href: link[2] });
      }
      else if (tok.startsWith('**')) out.push({ text: tok.slice(2, -2), bold: true });
      else                           out.push({ text: tok.slice(1, -1), italic: true });
      last = re.lastIndex;
   }
   plain(text.slice(last));
   return out.map(r => Object.assign({}, r, { text: unhold(r.text) }));
}

/* ------------------------------------------------------------------- HTML --*/
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function htmlInline(text) {
   return inline(text).map(r => {
      let s = esc(r.text);
      if (r.code)   return '<code>' + s + '</code>';
      if (r.bold)   return '<strong>' + s + '</strong>';
      if (r.italic) return '<em>' + s + '</em>';
      if (r.href)   return '<a href="' + esc(r.href) + '">' + s + '</a>';
      return s;
   }).join('');
}

const slug = s => s.toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s+/g, '-');

function htmlBlocks(blocks) {
   const o = [];
   for (const b of blocks) {
      switch (b.t) {
         case 'h':
            o.push(`<h${b.level} id="${slug(b.text)}">${htmlInline(b.text)}</h${b.level}>`);
            break;
         case 'p':
            o.push('<p>' + htmlInline(b.text) + '</p>');
            break;
         case 'hr':
            o.push('<hr>');
            break;
         case 'code':
            o.push('<pre><code>' + esc(b.lines.join('\n')) + '</code></pre>');
            break;
         case 'quote':
            o.push('<blockquote>' + htmlBlocks(b.blocks) + '</blockquote>');
            break;
         case 'list': {
            const tag = b.ordered ? 'ol' : 'ul';
            const task = b.items.some(t => /^\[[ x]\]\s/.test(t));
            o.push(`<${tag}${task ? ' class="task"' : ''}>`);
            for (const it of b.items) {
               const t = it.replace(/^\[ \]\s/, '☐ ').replace(/^\[x\]\s/i, '☑ ');
               o.push('<li>' + htmlInline(t) + '</li>');
            }
            o.push(`</${tag}>`);
            break;
         }
         case 'table': {
            o.push('<div class="tw"><table><thead><tr>');
            b.head.forEach((c, n) =>
               o.push(`<th style="text-align:${b.align[n] || 'left'}">${htmlInline(c)}</th>`));
            o.push('</tr></thead><tbody>');
            for (const r of b.rows) {
               o.push('<tr>');
               b.head.forEach((_, n) =>
                  o.push(`<td style="text-align:${b.align[n] || 'left'}">${htmlInline(r[n] || '')}</td>`));
               o.push('</tr>');
            }
            o.push('</tbody></table></div>');
            break;
         }
      }
   }
   return o.join('\n');
}

const CSS = `
:root{--ink:#1a1d21;--ink-2:#41484f;--ink-3:#6d757e;--line:#e2e5ea;--line-2:#eef0f3;
--bg:#fff;--soft:#f7f8fa;--accent:#1d4ed8;--quote:#8a6100;--quote-bg:#fdf8ec}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
-webkit-font-smoothing:antialiased}
.wrap{max-width:860px;margin:0 auto;padding:48px 28px 96px}
h1{font-size:32px;line-height:1.25;letter-spacing:-.02em;margin:0 0 8px}
h2{font-size:22px;letter-spacing:-.01em;margin:44px 0 12px;padding-bottom:8px;
border-bottom:1px solid var(--line)}
h3{font-size:17.5px;margin:30px 0 8px}
h4{font-size:15.5px;margin:22px 0 6px;color:var(--ink-2)}
p{margin:0 0 14px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
hr{border:0;border-top:1px solid var(--line);margin:34px 0}
code,pre{font-family:ui-monospace,SFMono-Regular,"Cascadia Mono",Consolas,monospace}
code{font-size:.88em;background:var(--soft);border:1px solid var(--line-2);
border-radius:4px;padding:.1em .38em}
pre{background:var(--soft);border:1px solid var(--line);border-radius:8px;
padding:14px 16px;overflow-x:auto;margin:0 0 18px;font-size:13px;line-height:1.5}
pre code{background:none;border:0;padding:0;font-size:inherit}
blockquote{margin:0 0 18px;padding:14px 18px;background:var(--quote-bg);
border-left:3px solid var(--quote);border-radius:0 6px 6px 0}
blockquote>:last-child{margin-bottom:0}
blockquote h3{margin-top:0;color:var(--quote)}
ul,ol{margin:0 0 16px;padding-left:26px}
li{margin-bottom:5px}
ul.task{list-style:none;padding-left:4px}
.tw{overflow-x:auto;margin:0 0 20px}
table{width:100%;border-collapse:collapse;font-size:14.5px}
th{background:var(--soft);text-align:left;font-weight:600;font-size:12.5px;
text-transform:uppercase;letter-spacing:.04em;color:var(--ink-3);
padding:9px 12px;border-bottom:2px solid var(--line);white-space:nowrap}
td{padding:9px 12px;border-bottom:1px solid var(--line-2);vertical-align:top}
tbody tr:last-child td{border-bottom:none}
@media print{.wrap{max-width:none;padding:0}pre,table{break-inside:avoid}}
@media (prefers-color-scheme:dark){
:root{--ink:#e6e8eb;--ink-2:#b3b9c0;--ink-3:#8b929a;--line:#2c3138;--line-2:#242830;
--bg:#15181c;--soft:#1c2026;--accent:#7aa2f7;--quote:#d9a441;--quote-bg:#241f13}}
`;

function toHtml(md, title) {
   return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>${CSS}</style>
</head><body><div class="wrap">
${htmlBlocks(parse(md))}
</div></body></html>
`;
}

/* ------------------------------------------------------------------- DOCX --*/
const xe = s => String(s)
   .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
   .replace(/"/g, '&quot;')
   .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '');

function runs(text, opt) {
   opt = opt || {};
   return inline(text).map(r => {
      const props = [];
      if (r.code)                 props.push('<w:rStyle w:val="CodeChar"/>');
      if (r.bold   || opt.bold)   props.push('<w:b/>');
      if (r.italic || opt.italic) props.push('<w:i/>');
      if (r.href && !r.href.startsWith('#')) props.push('<w:color w:val="1D4ED8"/>');
      const rPr = props.length ? '<w:rPr>' + props.join('') + '</w:rPr>' : '';
      return '<w:r>' + rPr + '<w:t xml:space="preserve">' + xe(r.text) + '</w:t></w:r>';
   }).join('');
}

function para(content, style, extra) {
   const pPr = '<w:pPr>' + (style ? `<w:pStyle w:val="${style}"/>` : '') + (extra || '') + '</w:pPr>';
   return '<w:p>' + pPr + content + '</w:p>';
}

function docxBlocks(blocks, indent) {
   indent = indent || 0;
   const ind = indent ? `<w:ind w:left="${indent}"/>` : '';
   const o = [];

   for (const b of blocks) {
      switch (b.t) {
         case 'h':
            o.push(para(runs(b.text), 'Heading' + Math.min(b.level, 4), ind));
            break;

         case 'p':
            o.push(para(runs(b.text), null, ind));
            break;

         case 'hr':
            o.push('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" '
                 + 'w:color="D5D9DE"/></w:pBdr><w:spacing w:before="240" w:after="240"/>'
                 + '</w:pPr></w:p>');
            break;

         case 'code': {
            // one paragraph, lines joined by breaks, so the shading is a single block
            const body = b.lines.map((l, n) =>
               (n ? '<w:br/>' : '') + '<w:t xml:space="preserve">' + xe(l) + '</w:t>').join('');
            o.push(para('<w:r>' + body + '</w:r>', 'CodeBlock', ind));
            break;
         }

         case 'quote':
            o.push(...docxBlocks(b.blocks, indent + 360).map(p =>
               p.replace('<w:pPr>', '<w:pPr><w:pBdr><w:left w:val="single" w:sz="18" '
                                  + 'w:space="8" w:color="C9A227"/></w:pBdr>')));
            break;

         case 'list':
            b.items.forEach((it, n) => {
               const mark = b.ordered ? (n + 1) + '.  '
                          : /^\[ \]\s/.test(it) ? '☐  '
                          : /^\[x\]\s/i.test(it) ? '☑  '
                          : '•  ';
               const text = it.replace(/^\[[ x]\]\s/i, '');
               o.push(para('<w:r><w:t xml:space="preserve">' + mark + '</w:t></w:r>' + runs(text),
                           null,
                           `<w:ind w:left="${indent + 360}" w:hanging="280"/>`
                           + '<w:spacing w:after="60"/>'));
            });
            break;

         case 'table': {
            const cols  = b.head.length;
            const width = Math.floor(9360 / cols);
            const cell = (txt, isHead, alignment) => {
               const jc = alignment === 'right'  ? '<w:jc w:val="right"/>'
                        : alignment === 'center' ? '<w:jc w:val="center"/>' : '';
               return '<w:tc><w:tcPr>'
                    + `<w:tcW w:w="${width}" w:type="dxa"/>`
                    + (isHead ? '<w:shd w:val="clear" w:fill="F4F6F8"/>' : '')
                    + '</w:tcPr>'
                    + para(runs(txt, { bold: isHead }), 'TableText', jc)
                    + '</w:tc>';
            };
            const border = w =>
               `<w:${w} w:val="single" w:sz="4" w:space="0" w:color="D8DCE1"/>`;
            o.push('<w:tbl><w:tblPr>'
                 + '<w:tblW w:w="9360" w:type="dxa"/>'
                 + '<w:tblBorders>' + ['top','left','bottom','right','insideH','insideV']
                      .map(border).join('') + '</w:tblBorders>'
                 + '<w:tblCellMar>'
                 + '<w:top w:w="60" w:type="dxa"/><w:left w:w="90" w:type="dxa"/>'
                 + '<w:bottom w:w="60" w:type="dxa"/><w:right w:w="90" w:type="dxa"/>'
                 + '</w:tblCellMar></w:tblPr>'
                 + '<w:tblGrid>' + b.head.map(() => `<w:gridCol w:w="${width}"/>`).join('') + '</w:tblGrid>'
                 + '<w:tr><w:trPr><w:tblHeader/></w:trPr>'
                 + b.head.map((c, n) => cell(c, true, b.align[n])).join('') + '</w:tr>'
                 + b.rows.map(r =>
                      '<w:tr>' + b.head.map((_, n) => cell(r[n] || '', false, b.align[n])).join('') + '</w:tr>'
                   ).join('')
                 + '</w:tbl>'
                 + '<w:p><w:pPr><w:spacing w:after="0" w:line="120" w:lineRule="exact"/></w:pPr></w:p>');
            break;
         }
      }
   }
   return o;
}

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
 <w:docDefaults><w:rPrDefault><w:rPr>
   <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>
   <w:sz w:val="21"/><w:szCs w:val="21"/><w:color w:val="1A1D21"/>
 </w:rPr></w:rPrDefault>
 <w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
 </w:docDefaults>
 <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
 <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
   <w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="0" w:after="200"/></w:pPr>
   <w:rPr><w:b/><w:sz w:val="44"/><w:color w:val="12151A"/></w:rPr></w:style>
 <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>
   <w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="140"/>
   <w:pBdr><w:bottom w:val="single" w:sz="6" w:space="4" w:color="D8DCE1"/></w:pBdr></w:pPr>
   <w:rPr><w:b/><w:sz w:val="30"/><w:color w:val="12151A"/></w:rPr></w:style>
 <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/>
   <w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="260" w:after="100"/></w:pPr>
   <w:rPr><w:b/><w:sz w:val="25"/></w:rPr></w:style>
 <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/>
   <w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/></w:pPr>
   <w:rPr><w:b/><w:sz w:val="22"/><w:color w:val="41484F"/></w:rPr></w:style>
 <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/>
   <w:basedOn w:val="Normal"/>
   <w:pPr><w:shd w:val="clear" w:fill="F5F6F8"/>
     <w:spacing w:before="80" w:after="160" w:line="240" w:lineRule="auto"/>
     <w:ind w:left="120" w:right="120"/>
     <w:pBdr>
       <w:top w:val="single" w:sz="4" w:space="6" w:color="E2E5EA"/>
       <w:left w:val="single" w:sz="4" w:space="6" w:color="E2E5EA"/>
       <w:bottom w:val="single" w:sz="4" w:space="6" w:color="E2E5EA"/>
       <w:right w:val="single" w:sz="4" w:space="6" w:color="E2E5EA"/>
     </w:pBdr></w:pPr>
   <w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="17"/></w:rPr>
 </w:style>
 <w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table Text"/>
   <w:basedOn w:val="Normal"/>
   <w:pPr><w:spacing w:before="20" w:after="20" w:line="240" w:lineRule="auto"/></w:pPr>
   <w:rPr><w:sz w:val="19"/></w:rPr></w:style>
 <w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/>
   <w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>
   <w:sz w:val="18"/><w:shd w:val="clear" w:fill="F0F2F5"/></w:rPr></w:style>
</w:styles>`;

const CONTENT_TYPES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="xml" ContentType="application/xml"/>
 <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
 <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
 <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>`;

const ROOT_RELS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
 <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>`;

const DOC_RELS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`;

const coreXml = title => `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties
 xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
 xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:dcterms="http://purl.org/dc/terms/"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
 <dc:title>${xe(title)}</dc:title>
 <dc:subject>KTP Payment Factory - OP schema anonymization</dc:subject>
 <dcterms:created xsi:type="dcterms:W3CDTF">${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}</dcterms:created>
</cp:coreProperties>`;

function toDocx(md) {
   return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
${docxBlocks(parse(md)).join('\n')}
<w:sectPr>
 <w:pgSz w:w="11906" w:h="16838"/>
 <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"
          w:header="567" w:footer="567" w:gutter="0"/>
</w:sectPr>
</w:body></w:document>`;
}

/* --------------------------------------------------------------- packaging --
 * Compress-Archive is avoided: on Windows PowerShell 5.1 it can write entry
 * names with a backslash separator, which Word will not open. ZipArchive with
 * explicit entry names does not have that problem.
 */
function zipDocx(parts, outFile) {
   const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'docx-'));
   for (const [name, body] of Object.entries(parts)) {
      const p = path.join(stage, name.replace(/\//g, path.sep));
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, body, 'utf8');           // no BOM
   }
   const names = Object.keys(parts).join('|');
   const ps = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$out = '${outFile.replace(/'/g, "''")}'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
foreach ($n in '${names}'.Split('|')) {
  $src = Join-Path '${stage.replace(/'/g, "''")}' ($n -replace '/', '\\')
  $e = $zip.CreateEntry($n, [System.IO.Compression.CompressionLevel]::Optimal)
  $w = New-Object System.IO.StreamWriter($e.Open(), (New-Object System.Text.UTF8Encoding($false)))
  $w.Write([System.IO.File]::ReadAllText($src, (New-Object System.Text.UTF8Encoding($false))))
  $w.Dispose()
}
$zip.Dispose()
`;
   execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps], { stdio: 'pipe' });
   fs.rmSync(stage, { recursive: true, force: true });
}

/* -------------------------------------------------------------------- main --*/
const targets = fs.readdirSync(DOCS).filter(f => f.endsWith('.md'));
if (!targets.length) { console.error('No .md files in docs/'); process.exit(1); }

for (const file of targets) {
   const md    = fs.readFileSync(path.join(DOCS, file), 'utf8');
   const first = parse(md).find(b => b.t === 'h');
   const title = first ? first.text.replace(/[*`]/g, '') : path.basename(file, '.md');
   const base  = path.join(DOCS, path.basename(file, '.md'));

   fs.writeFileSync(base + '.html', toHtml(md, title), 'utf8');

   zipDocx({
      '[Content_Types].xml'   : CONTENT_TYPES,
      '_rels/.rels'           : ROOT_RELS,
      'docProps/core.xml'     : coreXml(title),
      'word/_rels/document.xml.rels': DOC_RELS,
      'word/styles.xml'       : STYLES,
      'word/document.xml'     : toDocx(md)
   }, base + '.docx');

   console.log('  ' + file + '  ->  .html  .docx');
}
console.log('done');
