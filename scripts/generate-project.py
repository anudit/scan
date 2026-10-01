#!/usr/bin/env python3
"""Generate the small Xcode app + Quick Look project without third-party tools."""
import hashlib, json, pathlib, plistlib
root=pathlib.Path(__file__).resolve().parent.parent
objects={}
def ref(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(keyname,isa,**fields):
    key=ref(keyname);objects[key]={'isa':isa,**fields};return key
files=[]
for path in sorted((root/'App').glob('*.swift')):
    file=obj(str(path.relative_to(root)),'PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(path.relative_to(root)),sourceTree='<group>')
    files.append(obj('build:'+path.name,'PBXBuildFile',fileRef=file))
qlfile=obj('QuickLook/PreviewViewController.swift','PBXFileReference',lastKnownFileType='sourcecode.swift',path='QuickLook/PreviewViewController.swift',sourceTree='<group>')
qlbuild=obj('qlbuild','PBXBuildFile',fileRef=qlfile)
appProduct=obj('appProduct','PBXFileReference',explicitFileType='wrapper.application',path='Scan.app',sourceTree='BUILT_PRODUCTS_DIR')
qlProduct=obj('qlProduct','PBXFileReference',explicitFileType='wrapper.app-extension',path='ScanQuickLook.appex',sourceTree='BUILT_PRODUCTS_DIR')
products=obj('products','PBXGroup',children=[appProduct,qlProduct],name='Products',sourceTree='<group>')
main=obj('main','PBXGroup',children=[k for k,v in objects.items() if v['isa']=='PBXFileReference' and k not in [appProduct,qlProduct]]+[products],sourceTree='<group>')
package=obj('local','XCLocalSwiftPackageReference',relativePath='.')
def configs(name,settings):
    ids=[]
    for kind in ['Debug','Release']:
        specific={**settings,'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if kind=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if kind=='Debug' else 'dwarf-with-dsym'}
        ids.append(obj(name+kind,'XCBuildConfiguration',buildSettings=specific,name=kind))
    return obj(name+'configs','XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
common={'MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'6.0','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'-','ENABLE_HARDENED_RUNTIME':'YES','SDKROOT':'macosx','ARCHS':'arm64','ONLY_ACTIVE_ARCH':'YES'}
def target(name,product,sources,info,bundle,extension=False,extra=[]):
    deps=[];frameworks=[]
    for p in ['ScanEngine','ScanGrid','ScanTheme','ScanQuery']:
        dep=obj(name+p,'XCSwiftPackageProductDependency',package=package,productName=p);deps.append(dep);frameworks.append(obj(name+p+'link','PBXBuildFile',productRef=dep))
    src=obj(name+'sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sources,runOnlyForDeploymentPostprocessing=0)
    fw=obj(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0)
    settings={**common,'PRODUCT_NAME':'ScanQuickLook' if extension else 'Scan','PRODUCT_BUNDLE_IDENTIFIER':bundle,'INFOPLIST_FILE':info,'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks'],'CODE_SIGN_ENTITLEMENTS':'QuickLook/QuickLook.entitlements' if extension else 'App/Scan.entitlements'}
    if extension:settings.update({'SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES'})
    return obj(name,'PBXNativeTarget',buildConfigurationList=configs(name,settings),buildPhases=[src,fw]+extra,buildRules=[],dependencies=[],name=name,packageProductDependencies=deps,productName=name,productReference=product,productType='com.apple.product-type.app-extension' if extension else 'com.apple.product-type.application')
icon_file=obj('App/AppIcon.icns','PBXFileReference',lastKnownFileType='image.icns',path='App/AppIcon.icns',sourceTree='<group>')
icon_build=obj('icon_build','PBXBuildFile',fileRef=icon_file)
res=obj('appResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[icon_build],runOnlyForDeploymentPostprocessing=0)
ql=target('ScanQuickLook',qlProduct,[qlbuild],'QuickLook/Info.plist','dev.scan.app.preview',True)
embedfile=obj('embedfile','PBXBuildFile',fileRef=qlProduct,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=obj('embed','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embedfile],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0)
app=target('ScanDesktop',appProduct,files,'App/Info.plist','dev.scan.app',extra=[res,embed])
proxy=obj('proxy','PBXContainerItemProxy',containerPortal=ref('project'),proxyType=1,remoteGlobalIDString=ql,remoteInfo='ScanQuickLook')
dependency=obj('dependency','PBXTargetDependency',target=ql,targetProxy=proxy);objects[app]['dependencies']=[dependency]
project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'1600','BuildIndependentTargetsInParallel':'YES'},buildConfigurationList=configs('project',common),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,packageReferences=[package],productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,ql])
def encode(value,indent=0):
    if isinstance(value,dict):return '{\n'+''.join('\t'*(indent+1)+json.dumps(k)+' = '+encode(v,indent+1)+';\n' for k,v in value.items())+'\t'*indent+'}'
    if isinstance(value,list):return '('+', '.join(encode(v,indent) for v in value)+')'
    return str(value) if isinstance(value,int) else json.dumps(value)
projectdir=root/'Scan.xcodeproj';projectdir.mkdir(exist_ok=True)
(projectdir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
qlinfo={'CFBundleName':'ScanQuickLook','CFBundleIdentifier':'dev.scan.app.preview','CFBundleExecutable':'ScanQuickLook','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'100','LSMinimumSystemVersion':'14.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.quicklook.preview','NSExtensionPrincipalClass':'ScanQuickLook.PreviewProvider','NSExtensionAttributes':{'QLIsDataBasedPreview':True,'QLSupportedContentTypes':['public.comma-separated-values-text','public.tab-separated-values-text','dev.scan.jsonl','org.gnu.gnu-zip-archive','org.apache.parquet','org.duckdb.database','org.sqlite.sqlite3'],'QLSupportsSearchableItems':False}}}
with (root/'QuickLook/Info.plist').open('wb') as f:plistlib.dump(qlinfo,f)
with (root/'QuickLook/QuickLook.entitlements').open('wb') as f:plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True},f)
