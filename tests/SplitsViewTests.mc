import Toybox.Test;
(:test)
function scrolling(logger) {
    var v = new SplitsView();
    v._items = [[0,98,630,1000.0,630.0,1000], [1,25,2000,0,0,2000], [0,99,3900,100000.0,630.0,3000]];
    v._lapCount=99;
    v._topIndex=2;
    for (var mode=0; mode<3; mode+=1) {
        v._fontMode=mode; v.clampTop();
        Test.assertEqual(v._topIndex,2);
        v.pageOlder(); Test.assertEqual(v._topIndex,1);
        v._topIndex=-10; v.clampTop(); Test.assertEqual(v._topIndex,0);
        v._topIndex=10; v.clampTop(); Test.assertEqual(v._topIndex,3);
        Test.assertEqual(v.itemAt(v._topIndex)[1],100);
        Test.assertEqual(v.itemAt(v._topIndex)[5],-1);
        v._topIndex=2;
    }
    Test.assertEqual(v.fmtTime(3150),"52:30");
    Test.assertEqual(v.fmtTime(3900),"1h05");
    Test.assertEqual(v.fmtPaceU(630),v._useMiles ? "16:53" : "10:30");
    v._items=[]; v.clampTop(); Test.assertEqual(v._topIndex,0);
    return true;
}
(:test)
function retention(logger) {
    var v = new SplitsView();
    var removed=0;
    for (var i=1; i<=150; i+=1) {
        v._lapCount=i;
        v.addItem([0,i,3150,5000.0,630.0,i*3150000]);
        v._topIndex=v.nItems()+10; v.clampTop();
        Test.assertEqual(v.itemAt(v._topIndex)[1],i+1);
    }
    var s=Toybox.System.getSystemStats();
    logger.debug("retained="+v._items.size()+" used="+s.usedMemory+" free="+s.freeMemory);
    return true;
}

(:test)
function lactateAndUnits(logger) {
    var v=new SplitsView();
    v._items=[]; v._fieldRecord=null; v._fieldSession=null;
    v._val10=250; v.bump(1); Test.assertEqual(v._val10,250);
    v._val10=0; v.bump(-1); Test.assertEqual(v._val10,0);
    v._val10=20; v.confirmLactate();
    Test.assertEqual(v._topIndex,0); Test.assertEqual(v.itemAt(v._topIndex)[0],1);
    Test.assertEqual(v._pending,20); Test.assertEqual(v._holdSec,10);
    v._useMiles=true;Test.assertEqual(v.fmtPaceU(300),"8:02");
    v._useMiles=false;Test.assertEqual(v.fmtPaceU(300),"5:00");
    return true;
}
