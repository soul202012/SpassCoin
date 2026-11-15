-- SpassCoin: 8 neue Namensfarben (zusammen 15) und 8 neue Effekte (zusammen 12)
insert into public.shop_items (id, category, name, descr, price, rarity, data, active, sort) values
('name-white', 'name_color', 'Schneeweiss', 'Namensfarbe Schneeweiss', 50, 'common', '{"css":"#f8fafc"}', true, 7),
('name-violet', 'name_color', 'Violett', 'Namensfarbe Violett', 50, 'common', '{"css":"#a78bfa"}', true, 8),
('name-red', 'name_color', 'Feuerrot', 'Namensfarbe Feuerrot', 50, 'common', '{"css":"#f87171"}', true, 9),
('name-sunset', 'name_color', 'Sonnenuntergang', 'Verlauf Orange bis Pink', 150, 'rare', '{"css":"linear-gradient(90deg,#ff9a3c,#ff3c8e)"}', true, 10),
('name-ocean', 'name_color', 'Ozean', 'Verlauf Hellblau bis Blau', 150, 'rare', '{"css":"linear-gradient(90deg,#00c6ff,#0072ff)"}', true, 11),
('name-mint', 'name_color', 'Minze', 'Verlauf Grün bis Türkis', 150, 'rare', '{"css":"linear-gradient(90deg,#43e97b,#38f9d7)"}', true, 12),
('name-galaxy', 'name_color', 'Galaxie', 'Animierter Verlauf Lila, Pink, Blau', 300, 'epic', '{"css":"linear-gradient(90deg,#8b5cf6,#ec4899,#3b82f6,#8b5cf6)","animated":true}', true, 13),
('name-goldrush', 'name_color', 'Goldrausch', 'Animierter Gold-Glanz', 400, 'legendary', '{"css":"linear-gradient(90deg,#b8860b,#ffe57f,#d4af37,#fff6c2,#b8860b)","animated":true}', true, 14),
('fx-pulse', 'rank_effect', 'Puls', 'Der Name pulsiert sanft', 60, 'common', '{"class":"fx-pulse"}', true, 4),
('fx-wave', 'rank_effect', 'Welle', 'Die Buchstaben schwingen wie eine Welle', 100, 'rare', '{"class":"fx-wave","split":true}', true, 5),
('fx-shake', 'rank_effect', 'Zittern', 'Die Buchstaben zittern aufgeregt', 100, 'rare', '{"class":"fx-shake","split":true}', true, 6),
('fx-bounce', 'rank_effect', 'Hüpfen', 'Die Buchstaben hüpfen nacheinander', 200, 'epic', '{"class":"fx-bounce","split":true}', true, 7),
('fx-rainbow', 'rank_effect', 'Farbwechsel', 'Der Name wechselt ständig die Farbe', 200, 'epic', '{"class":"fx-rainbow"}', true, 8),
('fx-neon', 'rank_effect', 'Neonröhre', 'Leuchtet und flackert wie Neon', 250, 'epic', '{"class":"fx-neon"}', true, 9),
('fx-fire', 'rank_effect', 'Flammen', 'Der Name brennt', 400, 'legendary', '{"class":"fx-fire"}', true, 10),
('fx-spin', 'rank_effect', 'Salto', 'Die Buchstaben drehen sich der Reihe nach', 400, 'legendary', '{"class":"fx-spin","split":true}', true, 11)
on conflict (id) do nothing;
