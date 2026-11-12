# Publication figure: all 90 completed measurements and cell medians.
source('R/benchmark.R')
x <- readRDS('output/benchmark_results.rds')
stopifnot(nrow(x) == 90L, all(x$run_status == 'completed'))
s <- summarize_benchmark(x)
stopifnot(all(s$n_completed == 3L))
colors <- c('#D55E00', '#0072B2', '#009E73', '#CC79A7', '#6A51A3')
shapes <- c(16, 17, 15, 18, 8)
draw <- function() {
  layout(matrix(c(1,2,3,4,5,5), nrow=3, byrow=TRUE), heights=c(1,1,.15))
  par(mar=c(4.2,4.8,3.6,1.1), mgp=c(2.9,.8,0), tcl=-.25, las=1, family='sans')
  for (metric in c('runtime','memory')) for (j in 1:2) {
    inp <- names(benchmark_inputs)[j]
    r <- x[x$input == inp, ]; z <- s[s$input == inp, ]
    value <- if (metric=='runtime') r$elapsed_seconds/60 else r$maximum_resident_set_kb/1024^2
    plot(NA, xlim=c(.8,3.2), ylim=if(metric=='runtime') c(.7,700) else c(0,4.6),
         log=if(metric=='runtime') 'y' else '', axes=FALSE, xlab='Allocated cores',
         ylab=if(metric=='runtime') 'Elapsed time (minutes, log scale)' else 'GNU time maximum RSS (GiB)')
    ticks <- if(metric=='runtime') c(1,3,10,30,100,300) else 0:4
    abline(h=ticks, col='#E6E6E6', lwd=.6)
    axis(1,1:3,c('1','4','16')); axis(2,ticks,ticks); box(bty='l', col='#666666')
    title(main=if(j==1) 'Cincinnati sample' else 'Broadly distributed sample', cex.main=1.05, line=2)
    mtext(if(j==1) '10,000 records; 10,000 unique strings' else '100,000 records; 87,409 unique strings', side=3,line=.65,cex=.8)
    mtext(LETTERS[if(metric=='runtime') j else j+2], side=3,adj=0,line=2,font=2,cex=1.25)
    for (i in seq_along(benchmark_methods)) {
      zz <- z[z$method == names(benchmark_methods)[i], ]; rr <- r$method == names(benchmark_methods)[i]
      vv <- if(metric=='runtime') zz$median_elapsed_seconds/60 else zz$median_maximum_resident_set_gib
      off <- (i-3)*.045
      xx <- match(r$n_cores[rr],benchmark_cores)+off
      points(xx, value[rr], pch=1,col=adjustcolor(colors[i],.5),cex=.85)
      lines(match(zz$n_cores,benchmark_cores)+off,vv,col=colors[i],lwd=1.4,lty=i)
      points(match(zz$n_cores,benchmark_cores)+off,vv,col=colors[i],pch=shapes[i],cex=.95)
    }
  }
  par(mar=rep(0,4));plot.new()
  legend('center',legend=unname(benchmark_methods),col=colors,pch=shapes,lty=1:5,lwd=1.4,horiz=TRUE,bty='n',cex=.95,x.intersp=.7)
}
pdf('output/addr_benchmark_figure.pdf',width=10,height=8,useDingbats=FALSE);draw();dev.off()
png('output/addr_benchmark_figure.png',width=3000,height=2400,res=300,type='cairo');draw();dev.off()
