import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.System;
using Toybox.FitContributor;

// TSV-37: отдельное поле лактата. Список и ввод — два рисунка одного поля, потому что
// открыть второй экран поверх тренировки полю нельзя. Замер пишется в файл той же
// тренировки, на экран которой бегун добавил поле. app id — в manifest.xml; коннектор
// Runner MCP узнаёт замер по нему. Номера полей те же, что раньше были у поля кругов:
// 1 — поток, 2 — итог. Старые тренировки остаются на app id поля кругов.

// Тест ставит false до new: createField вне активности роняет прогон.
var _bindFit = true;

// Потолок списка на время тренировки. Протокол лактата — это десяток точек, не круги.
// Более ранняя точка при этом уже лежит в файле тренировки. Поднять — увеличить константу.
const SAMPLE_CAP = 30;

class LactateApp extends Application.AppBase {
    var _view;
    function initialize() { AppBase.initialize(); }
    function getInitialView() {
        _view = new LactateView();
        return [ _view, new LactateDelegate(_view) ];
    }
    function onSettingsChanged() {
        if (_view != null) { _view.reloadTheme(); WatchUi.requestUpdate(); }
    }
}

class LactateView extends WatchUi.DataField {
    var _samples;          // [val10, timerMs], val10 — десятые ммоль/л
    var _selected;         // запись в центре карусели, как выбранный круг в поле кругов
    var _mode;             // 0 список, 1 ввод
    var _val10;
    const MIN10 = 0;
    const MAX10 = 250;     // 25,0 ммоль/л
    var _pending;
    var _holdSec;
    var _fieldRecord;
    var _fieldSession;
    var _timerMs;
    var _w;
    var _h;
    var _light;
    var _bg;
    var _fg;
    var _dim;
    var _accent;
    var _card;
    var _fonts;
    var _fontIds;
    // Низ видимых цифр Golos от начала строки, в координатах макета 454.
    // Папки resources-<ширина> уже уменьшены под экран, а координаты идут через sc().
    var _digitBottom;

    function initialize() {
        DataField.initialize();
        _samples = [];
        _selected = 0;
        _mode = 0;
        _val10 = 20;       // старт ввода 2,0 — нижняя область лактатного порога
        _pending = 0;
        _holdSec = 0;
        _timerMs = 0;
        _w = 0;
        _h = 0;
        _fonts = null;
        _fontIds = null;
        _digitBottom = [ 16, 20, 20, 24, 36, 40, 48 ];
        _fieldRecord = null;
        _fieldSession = null;
        reloadTheme();
        if (_bindFit) {
            _fieldRecord = createField(
                "lactate", 1, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "mmol/L" }
            );
            _fieldSession = createField(
                "lactate_stop", 2, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "mmol/L" }
            );
        }
    }

    function reloadTheme() {
        var th = Application.Properties.getValue("theme");
        _light = (th != null && th == 1);
        if (_light) {
            _bg = 0xFFFFFF; _fg = 0x000000; _dim = 0x5C5C5C; _accent = 0x0086C8; _card = 0xEAF3ED;
        } else {
            _bg = 0x000000; _fg = 0xFFFFFF; _dim = 0x9A9A9A; _accent = 0x33CCFF; _card = 0x17231D;
        }
    }

    function compute(info) {
        // Буфер _pending (тот же приём, что держал замер в поле кругов, TSV-2 и TSV-31).
        // Record-поле FitContributor повторяет последнее значение в каждой следующей
        // записи, setData(null) роняет приложение, а запись вне compute теряется в гонке.
        // Поэтому compute раз в секунду пишет _pending и держит его _holdSec секунд
        // идущего таймера: Garmin на длинной тренировке прореживает поток, и одиночная
        // точка выпала бы. Часы пишут record-точки только при идущем таймере, поэтому
        // 10 секунд считаются, только пока растёт timerTime. Замер после «Стоп» ляжет
        // в поток после «Продолжить». Если бегун сохранит тренировку, не продолжив,
        // точек больше не будет: замер лежит и в итоговом session-поле, которое часы
        // пишут при сохранении. Когда замер отстоял 10 секунд в потоке, session-поле
        // обнуляется. Ненулевое значение в итоге — замер, которого в потоке нет.
        if (_fieldRecord == null) { return; }
        var tMs = (info != null && info.timerTime != null) ? info.timerTime : _timerMs;
        var running = (tMs != _timerMs);
        _timerMs = tMs;
        _fieldRecord.setData(_pending / 10.0);
        if (_pending != 0) {
            _fieldSession.setData(_pending / 10.0);
            if (running) { _holdSec -= 1; }
            if (_holdSec <= 0) {
                _pending = 0;
                _fieldSession.setData(0.0);
            }
        }
    }

    function bump(d10) {
        _val10 += d10;
        if (_val10 < MIN10) { _val10 = MIN10; }
        if (_val10 > MAX10) { _val10 = MAX10; }
        WatchUi.requestUpdate();
    }

    function confirm() {
        var info = Activity.getActivityInfo();
        var tMs = 0;
        if (info != null && info.timerTime != null) { tMs = info.timerTime; }
        _pending = _val10;
        _holdSec = 10;
        _samples.add([ _val10, tMs ]);
        while (_samples.size() > SAMPLE_CAP) { _samples.remove(_samples[0]); }
        _mode = 0;
        _selected = _samples.size() - 1;
        WatchUi.requestUpdate();
    }

    function valStr() { return valText(_val10); }
    function valText(v10) { return (v10 / 10).format("%d") + "," + (v10 % 10).format("%d"); }

    // Как время замера в списке поля кругов: минуты и секунды, без отдельного часа.
    function fmtClock(tMs) {
        var s = (tMs / 1000).toNumber();
        return (s / 60).format("%d") + ":" + (s % 60).format("%02d");
    }

    function sc(v) { return (v * ((_w < _h) ? _w : _h) / 454.0 + 0.5).toNumber(); }
    function px(v) { return (_w - sc(454)) / 2 + sc(v); }
    function py(v) { return (_h - sc(454)) / 2 + sc(v); }
    function clampSelected() {
        var n = _samples.size();
        if (n == 0) { _selected = 0; return; }
        if (_selected < 0) { _selected = 0; }
        if (_selected >= n) { _selected = n - 1; }
    }
    function nudge(d) {
        _selected += d;
        clampSelected();
    }
    function keyFont() {
        if (_h < 200) { return Graphics.FONT_TINY; }
        if (_h < 320) { return Graphics.FONT_SMALL; }
        return Graphics.FONT_MEDIUM;
    }
    function valueFont() {
        if (_h < 200) { return Graphics.FONT_MEDIUM; }
        if (_h < 320) { return Graphics.FONT_LARGE; }
        return Graphics.FONT_NUMBER_MILD;
    }

    // Зоны те же, что на проверенном вводе поля кругов: три колонки, два ряда,
    // возврат — левый край только в средней полосе, иначе углы +1 и −1 не нажимаются.
    function inputZoneAt(x, y) {
        if (x < _w * 0.16 && y > _h * 0.38 && y < _h * 0.62) { return "back"; }
        var col = (x < _w / 3) ? 0 : ((x < 2 * _w / 3) ? 1 : 2);
        var row = (y < _h / 2) ? 0 : 1;
        if (row == 0 && col == 0) { return "p1"; }
        if (row == 0 && col == 2) { return "p01"; }
        if (row == 1 && col == 0) { return "m1"; }
        if (row == 1 && col == 2) { return "m01"; }
        if (row == 1 && col == 1) { return "ok"; }
        return "";
    }

    function handleInput(z) {
        if (z.equals("p1")) { bump(10); }
        else if (z.equals("p01")) { bump(1); }
        else if (z.equals("m1")) { bump(-10); }
        else if (z.equals("m01")) { bump(-1); }
        else if (z.equals("ok")) { confirm(); }
        else if (z.equals("back")) { _mode = 0; WatchUi.requestUpdate(); }
    }

    function handleListTap(x, y) {
        // Правый край — ввод, верх и низ листают карусель. Так же, как в поле кругов.
        if (x > _w * 0.82) {
            _mode = 1;
            WatchUi.requestUpdate();
            return;
        }
        if (y < _h / 3) { nudge(-1); }
        else if (y > _h * 2 / 3) { nudge(1); }
        WatchUi.requestUpdate();
    }

    function onLayout(dc) {
        _w = dc.getWidth();
        _h = dc.getHeight();
        if (_fontIds == null) {
            // Те же размеры, что у карусели поля кругов: 0 край, 3 сосед, 6 центр.
            _fontIds = [
                Rez.Fonts.Tiny, Rez.Fonts.Row, Rez.Fonts.Number, Rez.Fonts.Near,
                Rez.Fonts.Dist, Rez.Fonts.Distmax, Rez.Fonts.Active
            ];
            _fonts = new [7];
        }
    }

    function onUpdate(dc) {
        if (_w == 0) { onLayout(dc); }
        dc.setAntiAlias(true);
        if (_mode == 1) { drawInput(dc); }
        else { drawList(dc); }
    }

    function font(f) {
        if (_fonts[f] == null) { _fonts[f] = WatchUi.loadResource(_fontIds[f]); }
        return _fonts[f];
    }
    function fitFont(dc, s, f, width) {
        while (f > 0 && dc.getTextWidthInPixels(s, font(f)) > sc(width)) { f -= 1; }
        return f;
    }
    function lineText(dc, s, x, y, width, f, color, align) {
        f = fitFont(dc, s, f, width);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(px(x), py(y), font(f), s, align);
        return f;
    }
    function valueText(dc, s, x, y, width, f, color, align) {
        f = lineText(dc, s, x, y, width, f, color, align);
        return y + _digitBottom[f];
    }
    function labelText(dc, s, x, inkTop, width, color) {
        lineText(dc, s, x, inkTop - 6, width, 1, color, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // Карусель MID поля кругов: пять мест, выбранный замер по центру.
    // Координаты и размеры шрифта скопированы оттуда, чтобы карточка совпала со снимком.
    function drawList(dc) {
        dc.setColor(_fg, _bg);
        dc.clear();
        var n = _samples.size();
        clampSelected();
        for (var i = 0; i < 5; i += 1) {
            var idx = _selected + i - 2;
            if (n == 0 || idx < 0 || idx >= n) { continue; }
            var x = 81; var y = 49; var w = 278; var h = 56; var size = 3;
            if (i == 0 || i == 4) { x = 117; w = 184; h = 52; size = 1; }
            else if (i == 2) { x = 34; w = 350; h = 115.4; size = 6; }
            else { x = 70; }
            if (i == 0) { y = 36; }
            else if (i == 1) { y = 94; }
            else if (i == 2) { y = 156; }
            else if (i == 3) { y = 277.4; }
            else { y = 339.4; }
            drawSample(dc, _samples[idx], x, y, w, h, size);
        }
        if (n == 0) { drawSample(dc, null, 34, 156, 350, 115.4, 6); }
        drawDrop(dc);
    }

    function drawSample(dc, it, x, y, w, h, size) {
        var active = (size == 6);
        dc.setColor(_card, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(px(x), py(y), sc(w), sc(h), sc(active ? 12 : 8));
        var left = x + (active ? 12 : 8);
        var right = x + w - (active ? 12 : 8);
        var l = Graphics.TEXT_JUSTIFY_LEFT;
        var r = Graphics.TEXT_JUSTIFY_RIGHT;
        lineText(dc, "lactate", left, y + (active ? 10 : 4), w / 2, active ? 2 : 0, _accent, l);
        lineText(dc, "mmol/L", right, y + 2, w / 2, 1, _dim, r);
        if (it == null) { return; }
        var bottom = valueText(dc, valText(it[0]), left, y + (active ? 44 : 26), w / 2, size, _accent, l);
        valueText(dc, fmtClock(it[1]), right, y + (active ? 44 : 26), w / 2, size, _dim, r);
        if (active) {
            labelText(dc, "value", left, bottom + 5, 100, _dim);
            labelText(dc, "time", right - 60, bottom + 5, 60, _dim);
        }
    }

    function drop(dc, x, y, h, color) {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y + h * 0.25, h * 0.35);
        dc.fillPolygon([ [x, y - h * 0.5], [x - h * 0.309, y + h * 0.087], [x + h * 0.309, y + h * 0.087] ]);
    }

    function drawDrop(dc) {
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(px(386), py(195), sc(64), sc(64), sc(20));
        drop(dc, px(418), py(227), sc(36), _bg);
    }

    function drawInput(dc) {
        var cw = _w / 3.0;
        var rh = _h / 2.0;
        var mid = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        var key = keyFont();
        dc.setColor(_fg, _bg);
        dc.clear();
        dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cw, _h * 0.12, cw, _h * 0.88);
        dc.drawLine(2 * cw, _h * 0.12, 2 * cw, _h * 0.88);
        dc.drawLine(_w * 0.08, rh, _w * 0.92, rh);
        dc.setColor(_accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw * 0.5, rh * 0.72, key, "+1", mid);
        dc.drawText(cw * 2.5, rh * 0.72, key, "+0,1", mid);
        var down = _light ? 0xC00000 : 0xFF5A5A;
        dc.setColor(down, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw * 0.5, rh * 1.28, key, "-1", mid);
        dc.drawText(cw * 2.5, rh * 1.28, key, "-0,1", mid);
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw * 1.5, rh * 0.42, valueFont(), valStr(), mid);
        var okW = cw * 0.72;
        var okH = rh * 0.42;
        var okX = cw * 1.5 - okW / 2;
        var okY = rh * 1.45;
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(okX, okY, okW, okH, _h * 0.04);
        dc.setColor(_bg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw * 1.5, okY + okH / 2, key, "OK", mid);
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w * 0.08, rh, key, "<", mid);
    }
}

class LactateDelegate extends WatchUi.BehaviorDelegate {
    var _view;
    function initialize(v) { BehaviorDelegate.initialize(); _view = v; }
    function onTap(evt) {
        var c = evt.getCoordinates();
        if (_view._mode == 1) { _view.handleInput(_view.inputZoneAt(c[0], c[1])); }
        else { _view.handleListTap(c[0], c[1]); }
        return true;
    }
}
