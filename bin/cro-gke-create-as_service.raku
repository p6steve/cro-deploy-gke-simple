#!/usr/bin/env raku
use lib '../lib';

#FIXME- change name to eg. deploy.raku??

use Cro::Deploy::GKE::Simple;

sub MAIN(
        Str $app-path='../examples',
        Str $app-name='hello-app',
        Str $app-tag='v1',
        Bool $run-local=False,
         ) {

    #Cluster params
    my $cluster-name="{$app-name}-cluster";
    my $replicas=3;
    my $cpu-percent=80;
    my $min=1;
    my $max=5;

    #Service params
    my $service-name="{$app-name}-service";
    my $port=80;
    my $target-port=8080;

    my $proc;       #re-used

    $proc = shell "gcloud config list", :out;
    my $config = $proc.out.slurp: :close;
    my %config = $config.split("\n").grep(/'='/).split(" = ").split(" ");

    my Str $project-id = %config<project>;
    my Str $project-zone = %config<zone>;

    say $app-path;
    say $app-name;
    say $app-tag;
    say $project-id;
    say $project-zone;

    chdir("$app-path/$app-name");
#`[
    say "Building and tagging docker image for GCR...";
    shell("docker build -t gcr.io/$project-id/$app-name:$app-tag .");

    say "Checking docker image...";
    say "REPOSITORY                   TAG            IMAGE ID       CREATED             SIZE";
    shell("docker images | grep 'gcr'");

    if $run-local {
        say "Checking image runs locally...";
        $proc = Proc::Async.new("echo checking...");
        $proc.start;
        $proc.ready.then: {
            shell("docker run --rm -p $target-port:$target-port gcr.io/$project-id/$app-name:$app-tag");
        }
        sleep 2;
        shell("curl http://localhost:$target-port");
        prompt("If OK, please stop docker container using app, OK to proceed?[ret]");
        $proc.kill(SIGTERM);
    }

    say "Enabling container registry API for project and docker auth...";
    shell("gcloud services enable containerregistry.googleapis.com");
    shell("gcloud auth configure-docker");

    say "Pushing docker image to GCR...";
    shell("docker push gcr.io/$project-id/$app-name:$app-tag");
#]
    sub cluster-up {
        my $proc = shell "kubectl get nodes", :out, :err;
        my $err = $proc.err.slurp: :close;
        my $out = $proc.out.slurp: :close;

        if    $out ~~ /Ready/   { True  }
        elsif $err ~~ /refused/ { False }
        else  { die "Error: can't figure out cluster status!" }
    }

    say "Checking cluster status...";
    if cluster-up() {
        say "Cluster already created."
    } else {
        say "Creating a GKE Standard cluster (please be patient) [$cluster-name]...";
        shell("gcloud container clusters create $cluster-name");
    }

    say "Connect to cluster...";
    shell("gcloud container clusters get-credentials $cluster-name --zone $project-zone");

    say "Create Kubernetes deployment...";
    shell("kubectl create deployment $app-name --image=gcr.io/$project-id/$app-name:$app-tag");
    shell("kubectl scale deployment $app-name --replicas=$replicas");
    shell("kubectl autoscale deployment $app-name --cpu-percent=$cpu-percent --min=$min --max=$max");
    shell("kubectl get pods");

    say "Expose to Internet...";
    shell("kubectl expose deployment $app-name --name=$service-name --type=LoadBalancer --port $port --target-port $target-port");

    $proc = shell "kubectl get service", :out;
    my $service = $proc.out.slurp: :close;

    say "deployment done";
}