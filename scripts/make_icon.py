from PIL import Image, ImageDraw, ImageFont
import os
S = 1024
img = Image.new("RGB", (S, S), (12, 16, 20))
d = ImageDraw.Draw(img)
for i in range(S):                      # 竖向渐变
    c = int(14 + 16 * (i / S))
    d.line([(0, i), (S, i)], fill=(c, c + 4, c + 8))
d.rounded_rectangle([64, 64, S-64, S-64], radius=190, outline=(47, 111, 235), width=18)
d.line([(200, 800), (420, 600)], fill=(47, 111, 235), width=26)
d.line([(420, 600), (330, 640)], fill=(47, 111, 235), width=26)
fp = None
for c in (r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf"):
    if os.path.exists(c): fp = c; break
f = ImageFont.truetype(fp, 430)
bb = d.textbbox((0, 0), "YG", font=f)
d.text(((S-(bb[2]-bb[0]))/2 - bb[0], (S-(bb[3]-bb[1]))/2 - bb[1] - 40), "YG", font=f, fill=(233, 242, 250))
img.save(r"D:\Ai破甲\DeepSeek Harness\yg-link\ios-repo\assets\icon-1024.png")
print("icon ok")
