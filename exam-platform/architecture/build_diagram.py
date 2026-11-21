"""Generates architecture/architecture.svg. Run: python3 build_diagram.py"""
W, H = 1500, 1040
o = []
def add(s): o.append(s)

C = {  # fill, stroke
 'edge': ('#ede7f6', '#7e57c2'), 'comp': ('#fff3e0', '#ef6c00'), 'net': ('#e8eaf6', '#3f51b5'),
 'data': ('#e3f2fd', '#1565c0'), 'store': ('#e8f5e9', '#2e7d32'), 'integ': ('#fce4ec', '#c2185b'),
 'sec': ('#ffebee', '#c62828'), 'ops': ('#eceff1', '#546e7a'), 'user': ('#fffde7', '#f9a825'),
}
def esc(t): return t.replace('&', '&amp;').replace('<', '&lt;')
def box(x, y, w, h, title, sub=None, kind='comp', dashed=False):
    f, s = C[kind]
    d = ' stroke-dasharray="6 4"' if dashed else ''
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{f}" stroke="{s}" stroke-width="1.6"{d}/>')
    if sub:
        add(f'<text x="{x+w/2}" y="{y+h/2-3}" text-anchor="middle" class="t">{esc(title)}</text>')
        add(f'<text x="{x+w/2}" y="{y+h/2+13}" text-anchor="middle" class="s">{esc(sub)}</text>')
    else:
        add(f'<text x="{x+w/2}" y="{y+h/2+5}" text-anchor="middle" class="t">{esc(title)}</text>')
def zone(x, y, w, h, label, stroke, fill='none', dash='', lx=None, anchor='start'):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="{fill}" stroke="{stroke}" stroke-width="1.5" stroke-dasharray="{dash}"/>')
    add(f'<text x="{(lx if lx is not None else x+12)}" y="{y+17}" text-anchor="{anchor}" class="z" fill="{stroke}">{esc(label)}</text>')
def line(pts, color='#37474f', dash='', arrow=True, width=1.8):
    p = ' '.join(f'{a},{b}' for a, b in pts)
    m = ' marker-end="url(#ah)"' if arrow else ''
    d = f' stroke-dasharray="{dash}"' if dash else ''
    add(f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="{width}"{d}{m}/>')
def label(x, y, t, color='#37474f', anchor='middle', cls='l'):
    add(f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="{cls}" fill="{color}">{esc(t)}</text>')

add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="system-ui,Segoe UI,Arial,sans-serif">')
add('''<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker>
<style>.t{font-size:13px;font-weight:600;fill:#1d2330}.s{font-size:11px;fill:#546e7a}.z{font-size:12px;font-weight:700}.l{font-size:11px;font-style:italic}.h{font-size:20px;font-weight:700;fill:#1d2330}</style></defs>''')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
add('<text x="24" y="34" class="h">Online exam platform: production architecture (AWS ap-south-1 Mumbai, 2 Availability Zones)</text>')

# ---------- edge band ----------
box(24, 120, 130, 70, 'Students, tutors,', 'admins (browser)', 'user')
box(280, 60, 190, 44, 'Route 53 + ACM', 'DNS name + TLS certificates', 'edge')
box(565, 128, 170, 60, 'CloudFront', 'HTTPS, CDN, /api/* to ALB', 'edge')
box(565, 196, 170, 38, 'AWS WAF', 'managed rules + flood limit', 'edge')
box(800, 128, 170, 60, 'S3: frontend', 'private, OAC only, TLS only', 'store')
box(985, 128, 160, 60, 'Cognito user pool', 'groups = student/tutor/admin', 'sec')
line([(154, 155), (565, 155)]); label(360, 148, 'HTTPS')
line([(470, 92), (600, 128)], '#7e57c2', '4 3')
line([(735, 158), (800, 158)])
# browser-direct paths
line([(89, 190), (89, 272), (1065, 272), (1065, 190)], '#1565c0', '7 4'); label(300, 266, 'sign in directly with Cognito, get an ID token', '#1565c0')
line([(1065, 272), (1325, 272), (1325, 338)], '#2e7d32', '7 4'); label(1195, 266, 'upload file straight to S3 (presigned POST)', '#2e7d32')

# ---------- VPC ----------
zone(180, 300, 960, 560, 'VPC 10.0.0.0/16 (internet gateway on the public route table)', '#3f51b5', '#fafbff')
for ax, name in ((196, 'Availability Zone A'), (684, 'Availability Zone B')):
    zone(ax, 326, 440, 505, name, '#78909c', '#ffffff', '3 3')
for ax, tag in ((212, 'a'), (700, 'b')):
    zone(ax, 352, 408, 88, f'public subnet {tag} 10.0.{0 if tag=="a" else 1}.0/24', '#5c6bc0', '#f3f4fb')
    zone(ax, 452, 408, 190, f'private app {tag} 10.0.1{0 if tag=="a" else 1}.0/24', '#ef6c00', '#fffaf3')
    zone(ax, 698, 408, 112, f'private data {tag} 10.0.2{0 if tag=="a" else 1}.0/24 (no internet route)', '#1565c0', '#f4f9ff')
box(228, 376, 120, 50, 'NAT gateway', 'AZ A', 'net'); box(950, 376, 140, 50, 'NAT gateway', 'AZ B', 'net')
box(370, 376, 560, 50, 'Application Load Balancer', 'spans both AZs, health checks on /health, only accepts CloudFront', 'net')
line([(650, 238), (650, 376)]); label(678, 300, '/api/*')

box(228, 490, 180, 56, 'API tasks (ECS Fargate)', 'Node/Express, autoscaled', 'comp'); box(716, 490, 180, 56, 'API tasks (ECS Fargate)', 'Node/Express, autoscaled', 'comp')
box(430, 568, 174, 56, 'Lambda workers', 'marking-fn, upload-fn', 'comp'); box(918, 568, 174, 56, 'Lambda workers', 'marking-fn, upload-fn', 'comp')
line([(440, 426), (385, 490)]); line([(900, 426), (870, 490)])
line([(250, 490), (250, 426)], '#78909c', '2 3'); line([(1010, 490), (1030, 426)], '#78909c', '2 3')
# DB bus
line([(318, 546), (318, 672)], arrow=False); line([(517, 624), (517, 672)], arrow=False)
line([(806, 546), (806, 672)], arrow=False); line([(1005, 624), (1005, 672)], arrow=False)
line([(318, 672), (1005, 672)], arrow=False)
line([(415, 672), (415, 728)]); label(560, 690, 'SQL over TLS (port 5432)', '#1565c0')
box(270, 728, 290, 54, 'RDS PostgreSQL: primary', 'Multi-AZ, KMS-encrypted, TLS enforced', 'data')
box(758, 728, 290, 54, 'RDS PostgreSQL: standby', 'synchronous copy, automatic failover', 'data')
line([(560, 755), (758, 755)], '#1565c0'); label(659, 748, 'sync replication', '#1565c0')
add('<polyline points="758,755 560,755" fill="none" stroke="#1565c0" stroke-width="1.8" marker-end="url(#ah)"/>')

# ---------- right column (managed services, outside VPC) ----------
box(1170, 338, 310, 56, 'S3: uploads', 'versioned, SSE, lifecycle rules, 5-year expiry', 'store')
zone(1170, 468, 310, 160, 'SQS queues (each with a dead-letter queue)', '#c2185b', '#fff8fb')
for i, n in enumerate(('marking', 'uploads', 'email')):
    box(1186, 492 + i * 42, 252, 34, f'{n} queue + DLQ', None, 'integ')
line([(1458, 394), (1458, 551), (1438, 551)], '#2e7d32', '7 4'); label(1450, 436, 'ObjectCreated', '#2e7d32', 'end')
box(1170, 656, 150, 56, 'Lambda: email-fn', 'outside VPC, no DB needed', 'comp'); box(1340, 656, 140, 56, 'Amazon SES', 'sends the emails', 'integ')
line([(1245, 628), (1245, 656)]); line([(1320, 684), (1340, 684)])
box(1170, 732, 150, 56, 'Secrets + KMS', 'DB password, data key', 'sec'); box(1340, 732, 140, 56, 'CloudWatch + SNS', 'logs, alarms, dashboard', 'ops')
box(1170, 802, 150, 48, 'ECR', 'API container image', 'comp'); box(1340, 802, 140, 48, 'S3 endpoint', 'free, skips the NAT', 'net')
line([(896, 512), (1170, 512)], '#78909c', '2 3'); label(1030, 505, 'enqueue (via NAT)', '#546e7a')
line([(1170, 596), (1092, 596)]); label(1131, 589, 'triggers', '#c2185b')
label(1480, 322, 'AWS managed services (outside the VPC)', '#546e7a', 'end', 'z')

# ---------- CI/CD ----------
zone(180, 880, 1300, 128, 'CI/CD: every push to main', '#546e7a', '#fafafa')
steps = [(196, 'GitHub repo', 'main branch'), (386, 'GitHub Actions', 'test, fmt, validate'), (596, 'Terraform apply', 'VPC, ECS, RDS, ...'), (806, 'docker build + push', 'image tagged with commit'), (1016, 'Publish frontend', 's3 sync + CloudFront clear')]
for x, a, b in steps: box(x, 920, 170 if x != 596 else 180, 56, a, b, 'ops')
for x1, x2 in ((366, 386), (556, 596), (776, 806), (986, 1016)): line([(x1, 948), (x2, 948)])
box(1250, 920, 210, 56, 'S3: Terraform state', 'versioned, encrypted, locked', 'store')
line([(1186, 948), (1250, 948)], '#546e7a', '2 3', arrow=False)
label(24, 1030, 'Solid arrow = request or data flow.  Blue dashed = sign-in.  Green dashed = direct upload and its S3 event.  Grey dotted = outbound traffic through the NAT gateway.', '#546e7a', 'start')
add('</svg>')
open('architecture.svg', 'w').write('\n'.join(o))
print('written')
