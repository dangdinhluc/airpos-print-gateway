#!/usr/bin/env python3
import sys
import zipfile
from xml.etree import ElementTree

with zipfile.ZipFile(sys.argv[1]) as archive:
    root = ElementTree.fromstring(archive.read('airpos-unicode.fnt'))
    info = root.find('info')
    common = root.find('common')
    assert info is not None and common is not None
    assert int(info.attrib['size']) == 24
    assert int(common.attrib['lineHeight']) >= 24
print('print font: 24px')
