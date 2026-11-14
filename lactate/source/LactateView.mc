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
    var _first;
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

    function initialize() {
        DataField.initialize();
        _samples = [];
        _first = 0;
        _mode = 0;
        _val10 = 20;       // старт ввода 2,0 — нижняя область лактатного порога
        _pending = 0;
        _holdSec = 0;
        _timerMs = 0;
        _w = 0;
        _h = 0;
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
            _bg = 0xFFFFFF; _fg = 0x000000; _dim = 0x5C5C5C; _accent = 0x0077B6;
        } else {
            _bg = 0x000000; _fg = 0xFFFFFF; _dim = 0x9A9A9A; _accent = 0x33CCFF;
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
        _first = _samples.size();
        shift(0);
        WatchUi.requestUpdate();
    }

    function valStr() { return valText(_val10); }
    function valText(v10) { return (v10 / 10).format("%d") + "," + (v10 % 10).format("%d"); }

    function fmtClock(tMs) {
        var s = (tMs / 1000).toNumber();
        var h = s / 3600;
        var m = (s % 3600) / 60;
        var sec = s % 60;
        if (h > 0) { return h.format("%d") + ":" + m.format("%02d") + ":" + sec.format("%02d"); }
        return m.format("%d") + ":" + sec.format("%02d");
    }

    function gutter() { return (_w * 0.18).toNumber(); }
    function listFont() {
        if (_h < 160) { return Graphics.FONT_XTINY; }
        if (_h < 280) { return Graphics.FONT_SMALL; }
        return Graphics.FONT_MEDIUM;
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
    function rowCount() {
        if (_h < 1) { return 5; }
        var rh = Graphics.getFontHeight(listFont()) + 6;
        var n = ((_h * 0.82) / rh).toNumber();
        if (n < 3) { n = 3; }
        if (n > 8) { n = 8; }
        return n;
    }
    function shift(d) {
        _first += d;
        var maxFirst = _samples.size() - rowCount();
        if (maxFirst < 0) { maxFirst = 0; }
        if (_first < 0) { _first = 0; }
        if (_first > maxFirst) { _first = maxFirst; }
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
        if (x > _w - gutter()) {
            _mode = 1;
            WatchUi.requestUpdate();
            return;
        }
        if (y < _h / 3) { shift(-1); }
        else if (y > _h * 2 / 3) { shift(1); }
        WatchUi.requestUpdate();
    }

    function onLayout(dc) {
        _w = dc.getWidth();
        _h = dc.getHeight();
    }

    function onUpdate(dc) {
        if (_w == 0) { onLayout(dc); }
        dc.setAntiAlias(true);
        if (_mode == 1) { drawInput(dc); }
        else { drawList(dc); }
    }

    function drawList(dc) {
        var g = gutter();
        var font = listFont();
        var mid = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        dc.setColor(_fg, _bg);
        dc.clear();
        var top = (_h * 0.08).toNumber();
        dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText((_w - g) / 2, top, Graphics.FONT_XTINY, "mmol/L", mid);
        var rows = rowCount();
        var n = _samples.size();
        var bodyTop = top + Graphics.getFontHeight(Graphics.FONT_XTINY);
        var rh = (_h - bodyTop) / rows;
        if (n == 0) {
            dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
            dc.drawText((_w - g) / 2, _h / 2, font, "Tap +", mid);
        } else {
            shift(0);
            for (var i = 0; i < rows; i += 1) {
                var idx = _first + i;
                if (idx >= n) { break; }
                var it = _samples[idx];
                var y = bodyTop + i * rh + rh / 2;
                var newest = (idx == n - 1);
                dc.setColor(newest ? _fg : _dim, Graphics.COLOR_TRANSPARENT);
                dc.drawText(8, y, font, fmtClock(it[1]), Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
                dc.setColor(newest ? _accent : _fg, Graphics.COLOR_TRANSPARENT);
                dc.drawText(_w - g - 6, y, font, valText(it[0]), Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
        var bw = g - 4;
        var bh = (_h * 0.22).toNumber();
        if (bh < 28) { bh = 28; }
        var bx = _w - bw - 2;
        var by = (_h - bh) / 2;
        dc.setColor(_accent, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(bx, by, bw, bh, 10);
        dc.setColor(_bg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bx + bw / 2, by + bh / 2, keyFont(), "+", mid);
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
