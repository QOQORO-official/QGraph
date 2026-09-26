/* Converts SVG into classic mxGraph XML and imports it through the legacy path. */
(function(root) {
    'use strict';

    var serial = 0;
    function num(value, fallback) {
        value = parseFloat(value);
        return isFinite(value) ? value : (fallback == null ? 0 : fallback);
    }
    function esc(value) {
        return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
    }
    function attribute(element, name, inherited, fallback) {
        var value = element.getAttribute(name);
        if (!value && element.style) value = element.style.getPropertyValue(name);
        if (!value && inherited) value = inherited[name];
        return value == null || value === '' ? fallback : value;
    }
    function presentation(element, inherited) {
        var result = {}, defaults = {
            fill:'#000000', stroke:'none', 'stroke-width':'1', opacity:'1',
            'stroke-dasharray':'', 'font-family':'Arial, Helvetica, sans-serif',
            'font-size':'12', 'font-weight':'normal', 'font-style':'normal',
            'text-anchor':'start', 'marker-start':'', 'marker-end':''
        };
        Object.keys(defaults).forEach(function(name) {
            result[name] = attribute(element, name, inherited, defaults[name]);
        });
        return result;
    }
    function multiply(a, b) {
        return {a:a.a*b.a+a.c*b.b, b:a.b*b.a+a.d*b.b,
            c:a.a*b.c+a.c*b.d, d:a.b*b.c+a.d*b.d,
            e:a.a*b.e+a.c*b.f+a.e, f:a.b*b.e+a.d*b.f+a.f};
    }
    function transform(value) {
        var result = {a:1,b:0,c:0,d:1,e:0,f:0};
        String(value || '').replace(/(matrix|translate|scale|rotate)\s*\(([^)]*)\)/g,
            function(match, kind, body) {
                var v = body.trim().split(/[\s,]+/).map(Number);
                var next = {a:1,b:0,c:0,d:1,e:0,f:0};
                if (kind === 'matrix' && v.length >= 6) next={a:v[0],b:v[1],c:v[2],d:v[3],e:v[4],f:v[5]};
                else if (kind === 'translate') { next.e=v[0]||0; next.f=v[1]||0; }
                else if (kind === 'scale') { next.a=v[0]||1; next.d=v.length>1?v[1]:next.a; }
                else if (kind === 'rotate') {
                    var r=(v[0]||0)*Math.PI/180, c=Math.cos(r), s=Math.sin(r);
                    next={a:c,b:s,c:-s,d:c,e:0,f:0};
                    if (v.length>2) next=multiply(multiply({a:1,b:0,c:0,d:1,e:v[1],f:v[2]},next),
                        {a:1,b:0,c:0,d:1,e:-v[1],f:-v[2]});
                }
                result=multiply(result,next);
                return match;
            });
        return result;
    }
    function pt(x, y, matrix) {
        return {x:matrix.a*x+matrix.c*y+matrix.e, y:matrix.b*x+matrix.d*y+matrix.f};
    }
    function box(points) {
        var xs=points.map(function(p){return p.x;}), ys=points.map(function(p){return p.y;});
        var x=Math.min.apply(Math,xs), y=Math.min.apply(Math,ys);
        return {x:x,y:y,width:Math.max.apply(Math,xs)-x,height:Math.max.apply(Math,ys)-y};
    }
    /* mxGraph rotates vertices around their center. Preserve a transformed
       rectangle's local aspect ratio instead of using its square-ish AABB. */
    function transformedRect(x, y, width, height, matrix) {
        var center=pt(x+width/2,y+height/2,matrix);
        var scaleX=Math.hypot(matrix.a,matrix.b), scaleY=Math.hypot(matrix.c,matrix.d);
        var dot=matrix.a*matrix.c+matrix.b*matrix.d;
        if(scaleX>0&&scaleY>0&&Math.abs(dot)<=.000001*scaleX*scaleY) {
            var transformedWidth=Math.abs(width*scaleX), transformedHeight=Math.abs(height*scaleY);
            return {bounds:{x:center.x-transformedWidth/2,y:center.y-transformedHeight/2,
                width:transformedWidth,height:transformedHeight},
                rotation:Math.atan2(matrix.b,matrix.a)*180/Math.PI};
        }
        return {bounds:box([pt(x,y,matrix),pt(x+width,y,matrix),
            pt(x,y+height,matrix),pt(x+width,y+height,matrix)]),rotation:0};
    }
    function styleText(style, shape, extra) {
        var values={shape:shape,html:0,fillColor:style.fill,strokeColor:style.stroke,
            strokeWidth:num(style['stroke-width'],1),opacity:num(style.opacity,1)*100,
            dashed:style['stroke-dasharray']?1:0,startArrow:style['marker-start']?'classic':'none',
            endArrow:style['marker-end']?'classic':'none',endFill:style['marker-end']?1:0};
        Object.assign(values,extra||{});
        return Object.keys(values).filter(function(k){return values[k]!=null;})
            .map(function(k){return k+'='+values[k]+';';}).join('');
    }
    function geometry(bounds) {
        return '<mxGeometry x="'+bounds.x+'" y="'+bounds.y+'" width="'+Math.max(.1,bounds.width)+
            '" height="'+Math.max(.1,bounds.height)+'" as="geometry" />';
    }
    function vertex(value, bounds, style) {
        serial++;
        return '<mxCell id="svg-'+serial+'" value="'+esc(value)+'" style="'+esc(style)+
            '" vertex="1" parent="1">'+geometry(bounds)+'</mxCell>';
    }
    function edge(points, style, circular) {
        if (!points || points.length<2) return '';
        serial++;
        var source=points[0], target=points[points.length-1], waypoints='';
        if (!circular && points.length>2) waypoints='<Array as="points">'+points.slice(1,-1).map(function(p){
            return '<mxPoint x="'+p.x+'" y="'+p.y+'" />';}).join('')+'</Array>';
        return '<mxCell id="svg-'+serial+'" value="" style="'+esc(style)+'" edge="1" parent="1">'+
            '<mxGeometry relative="1" as="geometry"><mxPoint x="'+source.x+'" y="'+source.y+
            '" as="sourcePoint" />'+waypoints+'<mxPoint x="'+target.x+'" y="'+target.y+
            '" as="targetPoint" /></mxGeometry></mxCell>';
    }
    function tokens(data) {
        return String(data||'').match(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:e[-+]?\d+)?/ig)||[];
    }
    function paths(data, matrix, style, warnings) {
        var t=tokens(data), i=0, command='', current={x:0,y:0}, start=null, sub=[], result=[];
        function read(){return num(t[i++]);}
        function flush(){if(sub.length>1) result.push(edge(sub,styleText(style,'none',{edgeStyle:'none'})));sub=[];}
        while(i<t.length) {
            if (/^[a-z]$/i.test(t[i])) command=t[i++];
            var relative=command===command.toLowerCase(), upper=command.toUpperCase();
            if (upper==='M'||upper==='L') {
                var x=read(),y=read(); if(relative){x+=current.x;y+=current.y;}
                if(upper==='M'){flush();start={x:x,y:y};command=relative?'l':'L';}
                current={x:x,y:y};sub.push(pt(x,y,matrix));
            } else if(upper==='H'||upper==='V') {
                var v=read(); if(upper==='H') current.x=relative?current.x+v:v;
                else current.y=relative?current.y+v:v; sub.push(pt(current.x,current.y,matrix));
            } else if(upper==='Q') {
                var qx=read(),qy=read(),ax=read(),ay=read();
                if(relative){qx+=current.x;qy+=current.y;ax+=current.x;ay+=current.y;}
                var q0={x:current.x,y:current.y};
                for(var q=1;q<=8;q++){var u=q/8,w=1-u;sub.push(pt(w*w*q0.x+2*w*u*qx+u*u*ax,w*w*q0.y+2*w*u*qy+u*u*ay,matrix));}
                current={x:ax,y:ay};
            } else if(upper==='C') {
                var x1=read(),y1=read(),x2=read(),y2=read(),cx=read(),cy=read();
                if(relative){x1+=current.x;y1+=current.y;x2+=current.x;y2+=current.y;cx+=current.x;cy+=current.y;}
                var c0={x:current.x,y:current.y};
                for(var c=1;c<=12;c++){var cu=c/12,cv=1-cu;sub.push(pt(cv*cv*cv*c0.x+3*cv*cv*cu*x1+3*cv*cu*cu*x2+cu*cu*cu*cx,cv*cv*cv*c0.y+3*cv*cv*cu*y1+3*cv*cu*cu*y2+cu*cu*cu*cy,matrix));}
                current={x:cx,y:cy};
            } else if(upper==='A') {
                var rx=read(),ry=read(),rotation=read(),large=read(),sweep=read(),ex=read(),ey=read();
                if(relative){ex+=current.x;ey+=current.y;}
                var source=pt(current.x,current.y,matrix),target=pt(ex,ey,matrix);
                if(sub.length===1&&Math.abs(rx-ry)<.01&&Math.abs(rotation)<.01&&i>=t.length) {
                    var chord=Math.hypot(ex-current.x,ey-current.y), angle=2*Math.asin(Math.min(1,chord/(2*Math.abs(rx))))*180/Math.PI;
                    if(large) angle=360-angle;
                    result.push(edge([source,target],styleText(style,'none',{edgeStyle:'none',qochartRoute:'circular',arcSweep:angle,arcSide:sweep?-1:1,circleRadius:Math.abs(rx)}),true));
                    sub=[];
                } else { warnings.push('A compound or elliptical arc was approximated by its endpoint.');sub.push(target); }
                current={x:ex,y:ey};
            } else if(upper==='Z') {
                if(start){current={x:start.x,y:start.y};sub.push(pt(start.x,start.y,matrix));} command='';
            } else { warnings.push('Unsupported path command '+command+' was skipped.');break; }
        }
        flush(); return result;
    }
    function convert(svgText) {
        serial=0;
        var doc=new DOMParser().parseFromString(String(svgText||''),'image/svg+xml');
        var error=doc.getElementsByTagName('parsererror')[0];
        if(error) throw new Error(error.textContent.replace(/\s+/g,' ').trim());
        var svg=doc.documentElement;
        if(!svg||svg.localName!=='svg') throw new Error('The input must contain an <svg> root element.');
        var view=String(svg.getAttribute('viewBox')||'').trim().split(/[\s,]+/).map(Number);
        var width=num(svg.getAttribute('width'),view[2]||300),height=num(svg.getAttribute('height'),view[3]||150);
        var matrix={a:1,b:0,c:0,d:1,e:view.length===4?-view[0]:0,f:view.length===4?-view[1]:0};
        var cells=[],warnings=[];
        function walk(element,inherited,parentMatrix) {
            var style=presentation(element,inherited),m=multiply(parentMatrix,transform(element.getAttribute('transform'))),name=element.localName;
            if(name==='svg'||name==='g'){Array.prototype.forEach.call(element.children,function(child){walk(child,style,m);});return;}
            if(name==='defs'||name==='marker'||name==='title'||name==='desc') return;
            if(name==='line') cells.push(edge([pt(num(element.getAttribute('x1')),num(element.getAttribute('y1')),m),pt(num(element.getAttribute('x2')),num(element.getAttribute('y2')),m)],styleText(style,'none',{edgeStyle:'none'})));
            else if(name==='polyline'||name==='polygon') {
                var raw=String(element.getAttribute('points')||'').trim().split(/[\s,]+/).map(Number),points=[];
                for(var p=0;p+1<raw.length;p+=2) points.push(pt(raw[p],raw[p+1],m));
                if(name==='polygon'&&points.length) points.push({x:points[0].x,y:points[0].y});
                cells.push(edge(points,styleText(style,'none',{edgeStyle:'none'})));
            } else if(name==='rect') {
                var x=num(element.getAttribute('x')),y=num(element.getAttribute('y')),w=num(element.getAttribute('width')),h=num(element.getAttribute('height'));
                var convertedRect=transformedRect(x,y,w,h,m);
                cells.push(vertex('',convertedRect.bounds,styleText(style,'rectangle',{
                    rounded:num(element.getAttribute('rx'))>0?1:0,
                    rotation:Math.abs(convertedRect.rotation)>.000001?convertedRect.rotation:null})));
            } else if(name==='circle'||name==='ellipse') {
                var cx=num(element.getAttribute('cx')),cy=num(element.getAttribute('cy')),rx=name==='circle'?num(element.getAttribute('r')):num(element.getAttribute('rx')),ry=name==='circle'?rx:num(element.getAttribute('ry'));
                cells.push(vertex('',box([pt(cx-rx,cy-ry,m),pt(cx+rx,cy-ry,m),pt(cx-rx,cy+ry,m),pt(cx+rx,cy+ry,m)]),styleText(style,'ellipse')));
            } else if(name==='text') {
                var tp=pt(num(element.getAttribute('x')),num(element.getAttribute('y')),m),text=element.textContent||'',fontSize=num(style['font-size'],12),tw=Math.max(fontSize,text.length*fontSize*.62),tx=tp.x;
                if(style['text-anchor']==='middle')tx-=tw/2;else if(style['text-anchor']==='end')tx-=tw;
                var fontStyle=(String(style['font-weight']).toLowerCase()==='bold'||num(style['font-weight'],400)>=700?1:0)+(style['font-style']==='italic'?2:0);
                var textRotation=Math.atan2(m.b,m.a)*180/Math.PI;
                cells.push(vertex(text,{x:tx,y:tp.y-fontSize,width:tw,height:fontSize*1.4},styleText(style,'text',{fillColor:'none',strokeColor:'none',fontColor:style.fill,fontFamily:style['font-family'],fontSize:fontSize,fontStyle:fontStyle,align:style['text-anchor']==='middle'?'center':(style['text-anchor']==='end'?'right':'left'),verticalAlign:'middle',rotation:Math.abs(textRotation)>.000001?textRotation:null})));
            } else if(name==='path') Array.prototype.push.apply(cells,paths(element.getAttribute('d'),m,style,warnings));
            else warnings.push('Unsupported <'+name+'> element was skipped.');
        }
        walk(svg,null,matrix); cells=cells.filter(Boolean);
        if(!cells.length) throw new Error('No supported editable SVG elements were found.');
        var xml='<mxGraphModel><root><mxCell id="0" /><mxCell id="1" parent="0" />'+cells.join('')+'</root></mxGraphModel>';
        var importer=root.PixelMxGraphFormat&&root.PixelMxGraphFormat.parse;
        if(typeof importer!=='function') importer=root.Editor&&root.Editor.importLegacyGraph;
        if(typeof importer!=='function') throw new Error('The mxGraph importer is not loaded.');
        var documentData=importer(xml);
        return {xml:xml,document:documentData,items:documentData.items||[],width:width,height:height,warnings:warnings};
    }
    root.SvgMxGraphConverter={convert:convert};
})(window);
