#!/usr/bin/env perl
# imagemagick redering converter from thumbgens xml files

$|=1;

use strict;
use Cwd;
use Getopt::Long;
use Image::Magick;
use XML::TokeParser;
use Data::Dumper;
use File::Basename;
use File::Finder;
use Math::Trig;
use XML::Bare;
use LWP::UserAgent;
use HTML::Entities;
use IO::Prompt;
use IMDB::Film;
use XML::RPC;

#---------------------------------------------------------------------------------------------
#
# Generic Logging Fuction
#
#---------------------------------------------------------------------------------------------
sub Logger {

# Log messages to output.  Below are the accepted logging levels, in decreasing value
#
# $level defines the level of the message
# $config_options->{LEVEL} is the level the user would like logging at
# all message at or above the user set level will be displayed
# CRIT will always display.
#     CRIT       critical conditions
#     ERROR      error conditions
#     WARN	     warning conditions
#     NOTICE     normal, but significant, condition
#     INFO       informational message
#     DEBUG      debug-level message
	
	my $config_options=shift;
	my $message=shift;
	my $level=shift;

	my %color=( 'DEBUG' 	=> "[35m",	 			# magenta
							'INFO'		=> "[37m",				# white
							'NOTICE'	=> "[36m",				# cyan
							'WARN'		=> "[32m",				# green
							'ERROR'		=> "[31m",				# red
							'CRIT'		=> "[41;37m",			# red background, white text
			);
	my %message_level=('DEBUG'   => 0,
       					     'INFO'    => 1,
              			 'NOTICE'  => 2,
              			 'WARN'    => 3,
              			 'ERROR'   => 4,
              			 'CRIT'    => 5,
      );

  open my $FD, ">> $config_options->{LOGFILE}" or die "unable to open $config_options->{LOGFILE}";
	print $FD "$level:\t$message\n";
	close $FD;

	if ($message_level{$config_options->{DEBUG}} <= $message_level{$level}){
		print STDERR "$color{$level}$level:[0m\t[33m$message[0m\n" if $config_options->{DEBUG};
	}
}

#---------------------------------------------------------------------------------------------
#
# Image Element Functions
#
#---------------------------------------------------------------------------------------------

sub DropShadow {
# add a shadow to the image
# the logic for this basically is to dup the image and make a shadow image.
# then position it according to distance and angle and composite the original on top
# yay math.

	my $config_options=shift;
	my $base_image=shift;
	my $true_angle=shift;
	my $color=shift;
	my $distance=shift;
	my $opacity=shift;
	my $softness=shift;
	my $delta_x;
	my $delta_y;
 	my $dir_x;
	my $dir_y;
	my $angle;

# get actual color translation
	$color=GetColor($config_options,$color);

# figure out the angle and offset
	if ( ($true_angle >= 270) && ($true_angle <= 360) ) {
		$angle = $true_angle-270;
		$dir_x = 1;
		$dir_y = 1;
	}
	elsif ( ($true_angle >= 180) && ($true_angle < 270) ) {
		$angle = $true_angle-180;
		$dir_x = -1;
		$dir_y = 1;
	}
	elsif ( ($true_angle >= 90) && ($true_angle < 180) ) {
		$angle = $true_angle-90;
		$dir_x = -1;
		$dir_y = -1;
	}
	elsif ( ($true_angle > 0) && ($true_angle < 90) ) {
		$angle=$true_angle;
		$dir_x = 1;
		$dir_y = -1;
	}
	elsif ($true_angle == 0) {
		$angle = 0;
		$dir_x = 1;
		$dir_y = 1;
	}

# now some happy trig to get the x and y deltas.  $distance is the hypoteneuse.

	$delta_x=int ( (sin(deg2rad($angle) )*$distance) * $dir_x ) ; # SIN A * distance = X
	$delta_y=int ( (cos(deg2rad($angle) )*$distance) * $dir_y ) ; # COS A * distance = Y

	my $shadow_image=Image::Magick->new(Magick=>'png');
	$shadow_image=$base_image->Clone();
	$shadow_image->Set(background=>'none');
	$shadow_image->Shadow(opacity=>$opacity,sigma=>$softness,X=>0, Y=>0);

	my ($width, $height) = $base_image->Get('columns', 'rows');
	my $new_image=Image::Magick->new(Magick=>'png');
	$new_image->Set( size=>sprintf("%dx%d",$width+(abs($delta_x)*2), $height+abs($delta_y)));
	$new_image->Read('xc:none');
	$new_image->Composite(image=>$base_image, compose=>'src');

	if ($delta_x < 0) { $new_image->Roll(x=>abs($delta_x)) }
	$new_image->Composite(image=>$shadow_image, compose=>'dst-over',X=>$delta_x, Y=>$delta_y); 

	undef $base_image;
	undef $shadow_image;
	return $new_image;
}

sub Glow {

	my $config_options=shift;
  my $base_image=shift;
  my $color=shift;
  my $opacity=shift;
  my $sigma=shift;

  my $color=GetColor($config_options,$color);
  my ($width, $height) = $base_image->Get('columns', 'rows');

  my $shadow_image=Image::Magick->new(Magick=>'png');
  $shadow_image=$base_image->Clone();
  $shadow_image->Set(background=>$color);
  $shadow_image->Shadow(opacity=>$opacity,sigma=>$sigma,X=>0, Y=>0);

  $shadow_image->Composite(image=>$base_image,x=>$sigma*2,y=>$sigma*2,compose=>'src-over');

  $shadow_image->Crop(x=>-$sigma,y=>-$sigma,width=>$width+(2*$sigma),height=>$height+(2*$sigma));
  return $shadow_image;

}


sub GlassTable {
# emulate the glasstable effect with ImageMagick
	my $config_options=shift;
	my $base_image=shift;
	my $x_offset=shift;
	my $y_offset=shift;
	my $opacity=shift;
	my $percent=shift;

	Logger($config_options,sprintf("Glass table parameters; X=%d Y=%d opacity=%d percent=%d",$x_offset,$y_offset,$opacity,$percent),"DEBUG");

			my ($width, $height) = $base_image->Get('columns', 'rows');
			my $first_image=Image::Magick->new();
			my $new_height=int($height*$percent/100);
			
			my $temp_image=Image::Magick->new();
			$temp_image=$base_image->Clone();
			$temp_image->Flip();
			$temp_image->Crop(sprintf("%dx%d+0+0", $width, $new_height) );
			
			my $temp_image2=Image::Magick->new();
			$temp_image2=$base_image->Clone();
			$temp_image2->Flip();
			$temp_image2->Crop(sprintf("%dx%d+0+0", $width, $new_height) );
			$temp_image2->Set(alpha=>'Extract');
			
			my $gradient=Image::Magick->new();
			$gradient->Set(size=>sprintf("%dx%d", $width, $new_height) );
			$gradient->Read("gradient:grey-black");
			
			$temp_image2->Composite(image=>$gradient, compose=>'Multiply');
			$temp_image2->Set(alpha=>'off');
			$temp_image->Set(alpha=>'off');
			
			$temp_image->Composite(image=>$temp_image2, compose=>'CopyOpacity');
			$temp_image->Set(alpha=>'on');
			
			$opacity=($opacity/100);
			$temp_image->Evaluate(value=>$opacity, operator=>'Multiply', channel=>'Alpha');
			
			my $clipboard=Image::Magick->new();
			push(@$clipboard, $base_image);
			push(@$clipboard, $temp_image);
			$base_image=$clipboard->Append();

# I have reworked the Glass Table to identify source images that already have transparency and treat them diferently

	#			my ($width, $height) = $base_image->Get('columns', 'rows');
	#			my $first_image=Image::Magick->new();
	#			my $new_height=int($height*$percent/100);
	#			
	#			my $temp_image=Image::Magick->new();
	#			$temp_image=$base_image->Clone();
	#			$temp_image->Flip();
	#			$temp_image->Crop(sprintf("%dx%d+0+0", $width, $new_height) );
	#			
	#			my $gradient=Image::Magick->new();
	#			$gradient->Set(size=>sprintf("%dx%d", $width, $new_height) );
	#			$gradient->Read("gradient:white-black");
	#			
	#			if ($base_image->Get('matte')) {
  	#			# this one has a transparent channel
		#			Logger($config_options,"Glass Tabling Transparent Image","DEBUG");
  	#			$gradient->Composite(image=>$temp_image, compose=>'dst-in');
  	#			$gradient->Set(alpha=>'extract');
  	#			$temp_image->Composite(image=>$gradient, compose=>'multiply');
  	#			$opacity=($opacity/100);
  	#			$temp_image->Evaluate(value=>$opacity, operator=>'Multiply', channel=>'Alpha');
  	#			$temp_image->Set(alpha=>'copy');
	#			
	#			}
	#			else {
 		#			# this one does not have a transparent channel
		#			Logger($config_options,"Glass Tabling NON Transparent Image","DEBUG");
  	#			$gradient->Set(alpha=>'copy');
  	#			$temp_image->Composite(image=>$gradient, compose=>'CopyOpacity');
  	#			$opacity=($opacity/100);
  	#			$temp_image->Evaluate(value=>$opacity, operator=>'Multiply', channel=>'Alpha');
	#			}
#			
	#			
	#			my $clipboard=Image::Magick->new();
	#			push(@$clipboard, $base_image);
	#			push(@$clipboard, $temp_image);
	#			$base_image=$clipboard->Append();

	return $base_image;
}	

sub Skew{
# Skewing is a fun problem.  ImageDraw specifies two different skews, Parallelogram and Trapezoid
# Parallelogram is exactly as it sounds, all four sides of an image remain the same length
# while Trapezoid actually adjust the image side length.
# Also there is the concept of Horizontal vs Vertical Skew
# this refers to which edge the angle is applied
# start with the image in the lower right quadrant of 2D space
# Horizontal is along the X axix, Vertical the Y
#
# of course ImageMagick is more generic.  We can pull off an image transform by simply specifying 
# 4 starting cordinates and their corresponding destination coordinates

	my $config_options=shift;
	my $orig_image=shift;
	my $angle=shift;
	my $contrainProportions=shift;
	my $orientation=shift;
	my $type=shift;
	my @skew_points;

	my ($width, $height) = $orig_image->Get('columns', 'rows');
	my $direction=$angle/abs($angle); # this give either 1 or -1
	$angle=abs($angle);

	# the math is different depending on horizontal or vertical skew.
	my $delta;
	if ($orientation =~ /Vertical/i ) {
		# Vertical means the width of the image is used
		$delta=int( (sin(deg2rad($angle) )*$width) ); 
	}
	else {
		# Horizontal means the height of the image is used
		$delta=int( (sin(deg2rad($angle) )*$height) ); 
	}

	if ( $type =~ /Parallelogram/i ) {
		# Let's deal with Parallelogram first.  
		if ( $orientation =~ /Vertical/i ) {
			# In the Vertical, +ve angle implies left side shifts down -ve implies right side shifts down
			# simple Parallelogram means we simply use the angle to figure out the delta up or down
			# of the right side of the image.  That means math TAN $angle = Delta / image width
			if ( $direction < 0 ) {	
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d 0,%d   %d,0 %d,%d   %d,%d %d,%d", #top left no move
					$height, $height, # bottom left does not move
					$width, $width, $delta, # top right slides down
					$width, $height, $width, $height+$delta, # bottom right slides down
					));
			}
			else {
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,%d   0,%d 0,%d   %d,0 %d,0   %d,%d %d,%d", $delta, # top left slides down
					$height, $height+$delta, # bottom left slides down
					$width, $width,  # top right stays the same
					$width, $height, $width, $height # bottom right stays the same
					));
			}
		}
		else {  # its Horizontal Parallelogram
			# In the Horizontal, +ve angle implies bottom of image shifts right -ve implies top shifts right
     	if ( $direction < 0 ) {
       	@skew_points=split(/[ ,]+/,sprintf("0,0 %d,0   0,%d 0,%d   %d,0 %d,0   %d,%d %d,%d", $delta, #top left slides right
         	$height, $height, # bottom left does not move
         	$width, $width+$delta, # top right slides right
         	$width, $height, $width, $height # bottom right does not move
         	));
     	}
     	else {
       	@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d %d,%d   %d,0 %d,0   %d,%d %d,%d",  # top left does not move
         	$height, $delta, $height, # bottom left slides right
         	$width, $width, # top right stays the same
         	$width, $height, $width+$delta, $height # bottom right slides right
         	));
     	}
    }
	}
	else { # this is the trapezoid distort
		if ( $orientation =~ /Vertical/i ) {
		# In the Vertical, -ve angle implies right side shrinks +ve angle implies left side shrinks
		# Trapezoid means we use the angle to figure out the delta up or down and apply that delta both corners of the image
			if ( $direction < 0 ) {	
				$orig_image->Resize(height=>($height+$delta));
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d 0,%d   %d,0 %d,%d   %d,%d %d,%d", # top left does not change
					$height, $height, # bottom left does not move
					$width, $width-$delta, $delta, # top right slides down
					$width, $height, $width-$delta, $height-$delta, # bottom right slides up
					));
			}
			else {
				$orig_image->Resize(height=>($height+$delta));
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,%d   0,%d 0,%d   %d,0 %d,0   %d,%d %d,%d", $delta, # top left slides down
					$height, $height-$delta, # bottom left slides up
					$width, $width,  # top right stays the same
					$width, $height, $width, $height # bottom right stays the same
					));
			}
		}
		else {  # its Horizontal Trapezoid
			# In the Horizontal, +ve angle implies bottom of image shrinks -ve implies top shrinks
     	if ( $direction < 0 ) {
       	@skew_points=split(/[ ,]+/,sprintf("0,0 %d,0   0,%d 0,%d   %d,0 %d,0   %d,%d %d,%d", $delta, #top left slides right
         	$height, $height, # bottom left stays the same
         	$width, $width-$delta, # top right slides left
         	$width, $height, $width, $height # bottom right does not change
         	));
     	}
     	else {
       	@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d %d,%d   %d,0 %d,0   %d,%d %d,%d",  # top left does not move
         	$height, $delta, $height, # bottom left slides right
         	$width, $width, # top right stays the same
         	$width, $height, $width-$delta, $height # bottom right slides left
         	));
     	}
		}
	}
	$orig_image->Set(alpha=>'off');
	$orig_image->Distort(points=>\@skew_points, "method"=>"Perspective", 'virtual-pixel'=>'transparent');
	$orig_image->Set(alpha=>'on');
	return $orig_image;
}

sub AdjustOpacity {
# set the transparency of an image
	my $config_options=shift;
	my $base_image=shift;
	my $opacity_percent=shift;



	if ($base_image->Get('matte')) {
		Logger($config_options,"Adjusting Opacity to $opacity_percent on image with transparency channel","DEBUG");
	}
	else {
		Logger($config_options,"Adjusting Opacity to $opacity_percent on image without transparency channel","DEBUG");
		my $opacity=Image::Magick->new(Magick=>'png');
		my ($width, $height) = $base_image->Get('columns', 'rows');
		$opacity->Set(size=>sprintf("%dx%d", $width, $height) );
		$opacity->Read("xc:white");
	  $opacity->Set(alpha=>'copy');
 	 	$base_image->Composite(image=>$opacity, compose=>'CopyOpacity');
	}
 	$base_image->Evaluate(value=>$opacity_percent, operator=>'Multiply', channel=>'Alpha');

	return $base_image;

#		$opacity=$base_image->Clone();

#		$base_image->Evaluate(value=>$opacity_percent,operator=>'Multiply',channel=>'Alpha');
#		$base_image->Set(alpha=>'extract');
#		$base_image->Evaluate(value=>$opacity_percent,operator=>'Multiply',channel=>'All');
#		$base_image->Set(alpha=>'copy');
#		$opacity->Composite(image=>$base_image,compose=>"copyopacity");
#		
#		
#		return $opacity;


}


sub PerspectiveView {
# create a perspectiveView of the passed in image
# initially this looks to be a trapezoid distort
	my $config_options=shift;
	my $orig_image=shift;
	my $angle=shift;
	my $orientation=shift;

	# basically we call Skew with a type of Trapezoid and Orientation of Vertical.  The -ve angle is left to right +ve right to left
	if ($orientation =~ /righttoleft/i) {
		$angle=(abs($angle)/2)*(-1);
	}
	else {
		$angle=abs($angle)/2;
	}
	return Skew($config_options,$orig_image, $angle, "True", "Vertical", "Trapezoid");
}

sub RoundCorners {
	my $config_options=shift;
	my $orig_image=shift;
	my $border_color=shift;
	my $border_width=shift;
	my $roundness=shift;
	my $corners=shift;

	my ($width, $height) = $orig_image->Get('columns', 'rows');

	my $TopLeft=Image::Magick->new(magick=>'png');
	my $base_image=Image::Magick->new(magick=>'png');
	my $white=Image::Magick->new(magick=>'png');
	my $trans=Image::Magick->new(magick=>'png');

	$base_image=$orig_image->Clone();
	$white->Set(size=>sprintf("%dx%d",$width,$height) );
	$white->Read("xc:white");
	$base_image->Set(alpha=>'off');
	$base_image->Composite(image=>$white, compose=>'SrcIn');

	# make a TopLeft Corner as a base and we will flip and flop as needed.
	my $points=sprintf("%d,%d %d,0",$roundness,$roundness,$roundness);
	$TopLeft->Set(size=>sprintf("%dx%d",$roundness,$roundness));
	$TopLeft->Read('xc:none');
	$TopLeft->Draw(primitive=>'circle', fill=>'white', points=>$points);
	$TopLeft->Set(alpha=>'off');

	if ( ($corners =~ /topleft/i ) || ( $corners =~ /All/i ) ) {
		# make a TopLeft overlay
		Logger($config_options,"TopLeft","DEBUG");
		$base_image->Composite(compose=>'src-atop',image=>$TopLeft,gravity=>'NorthWest');
	}
	if ( ( $corners =~ /topright/i ) || ( $corners =~ /All/i ) ) {
		# make a TopRight overlay
		my $TopRight=Image::Magick->new(magick=>'png');
		$TopRight=$TopLeft->Clone();
		$TopRight->Flop();
		Logger($config_options,"TopRight","DEBUG");
		$base_image->Composite(compose=>'src-atop',image=>$TopRight,gravity=>'NorthEast');
		undef $TopRight;
  }
  if( ( $corners =~ /bottomright/i ) || ( $corners =~ /All/i ) ) {
    # make a BottomRight overlay
		my $BottomRight=Image::Magick->new(magick=>'png');
		$BottomRight=$TopLeft->Clone();
		$BottomRight->Flop();
		$BottomRight->Flip();
		Logger($config_options,"BottomRight","DEBUG");
		$base_image->Composite(compose=>'src-atop',image=>$BottomRight,gravity=>'SouthEast');
		undef $BottomRight;
  }
  if( ( $corners =~ /bottomleft/i ) || ( $corners =~ /All/i ) ) {
	  # make a BottomLeft overlay
		my $BottomLeft=Image::Magick->new(magick=>'png');
		$BottomLeft=$TopLeft->Clone();
		$BottomLeft->Flip();
		Logger($config_options,"BottomLeft","DEBUG");
		$base_image->Composite(compose=>'src-atop',image=>$BottomLeft,gravity=>'SouthWest');
		undef $BottomLeft;
  }

	$base_image->Set(alpha=>'off');
	$white->Composite(image=>$base_image, compose=>'CopyOpacity');
	$white->Composite(image=>$orig_image, compose=>'in');

	$base_image=$white->Clone();

#if ( $border_width > 0 ) { 
## this is what I am thinking here.  clone the image. resize it by borderwidth fill it with the bordercolor
## lay the original image inside of the filled one.  The should give a border....
#my $border_image=Image::Magick->new(magick=>'png');
#$border_image=$base_image->Clone();
#($width, $height) = $base_image->Get('columns', 'rows');
#$border_color=GetColor($config_options,$border_color);
#$border_image->Resize(width=>$width+(2*$border_width),height=>$height+(2*$border_width));
#$border_image->Set(background=>$border_color);
#$border_image->Shadow(opacity=>100,sigma=>0,X=>0, Y=>0);
#$border_image->Composite(image=>$base_image,compose=>'src-over',x=>$border_width,y=>$border_width);
#$base_image=$border_image;
#undef $border_image;
#}
#undef $TopLeft;
#undef $orig_image;
#return $base_image;
	 if ( $border_width > 0 ) {
  	# this is what I am thinking here.  clone the image. resize it by borderwidth fill it with the bordercolor
  	# lay the original image inside of the filled one.  The should give a border....
    my $border_image=Image::Magick->new(magick=>'png');
    $border_image=$base_image->Clone();
    ($width, $height) = $base_image->Get('columns', 'rows');
    $border_image->Resize(width=>$width+(2*$border_width),height=>$height+(2*$border_width));
		$border_color=GetColor($config_options,$border_color);
    $border_image->Set(background=>$border_color);
    $border_image->Shadow(opacity=>100,sigma=>0,X=>0, Y=>0);

  	my $gif_image=Image::Magick->new(magick=>'gif');
  	$gif_image->Set(size=>sprintf('%dx%d',$width+(2*$border_width),$height+(2*$border_width)));
  	$gif_image->Read('xc:none');
  	$gif_image->Composite(image=>$base_image,compose=>'src',x=>$border_width,y=>$border_width);
  	$gif_image->Set(alpha=>'extract');

		$border_image->Composite(image=>$border_image,mask=>$gif_image,compose=>'clear');
		$border_image->Composite(image=>$base_image,compose=>'src-over',x=>$border_width,y=>$border_width);
    $base_image=$border_image;
    undef $border_image;
  }


return $base_image;

}

sub GetColor {
# take the signed int that ImageDraw uses and return a hex.  When converted from signed int to hex
# ImageDraw uses the following convention  AARRGGBB  Alpha Red Green Blue.  ImageMagick like
# RRGGBBAA so lets pass back a hash reference.
	my $config_options=shift;
	my $ID_color=shift;

	my $hex = sprintf ("%x",$ID_color);

	my $alpha= (substr($hex,0,2) ? substr($hex,0,2) : "00");
	my $red= (substr($hex,2,2) ? substr($hex,2,2) : "00");
	my $green= (substr($hex,4,2) ? substr($hex,4,2) : "00");
	my $blue= (substr($hex,6,2) ? substr($hex,6,2) : "00");

	#my $result = "#$red$green$blue$alpha";
	my $result = "#$red$green$blue";

	Logger($config_options,"GetColor Request orig->$ID_color result->$result","DEBUG");
	return $result;

}

sub AddImageElement {
# take the base image and laydown a composite on top
# all of the composite information will be in the composite_data variable
	my $config_options=shift;
	my $provider_hash=shift;
	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $template_xml=shift;
	my $sourceData;
	my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
	my $temp=Image::Magick->new(magick=>'png');
		
		$sourceData=$token->attr->{SourceData};
		if ( $sourceData =~ /\%RATINGSTARS\%/ ) {
			# this token is part of the Settings token in the template.xml file
			my $source=$template_xml->{Template}->{Settings}->{Rating}->{FileName}->{value};
			next unless DeTokenize($config_options,\$source,$provider_hash,$template_xml);
			my $rating=$provider_hash->{RATING};
    	$temp->Read($source);
			my ($width, $height) = $temp->Get('columns', 'rows');
			# single star
			if ($width>24) {
				$temp->Crop(width=>$width/2,height=>$height);
			}
			my $rating_image=Image::Magick->new(magick=>'png');

			my ($full_stars,$remainder) = split (/\./, $rating);
			my $clipboard=Image::Magick->new();

			for (my $count = 1; $count <= $full_stars; $count++) {
				push(@$clipboard, $rating_image);
				push(@$clipboard, $temp);
				$rating_image=$clipboard->Append(stack=>'false');
				@$clipboard=();
			}

			if ( $remainder > 0 ) {
				 # add a partial star
				$temp->Crop(width=>($width/2*$remainder/10), height=>$height);
				push(@$clipboard, $rating_image);
				push(@$clipboard, $temp);
				$rating_image=$clipboard->Append(stack=>'false');
				@$clipboard=();
			}

			$temp=$rating_image;

		}
		else {
			next unless DeTokenize($config_options,\$sourceData,$provider_hash,$template_xml);

			if ($sourceData eq "") {
				Logger($config_options,"I was unable to find image element information .. ".$token->attr->{Name},"CRIT");
				$temp->Read('xc:none');
				next;
			}

			if ( $sourceData =~ /^http/i ) {
				Logger($config_options,"grabbing $sourceData from the web","INFO");
    		if ($temp->Read($sourceData)) {
					Logger($config_options,"Unable to load image at $sourceData","CRIT");
					next;
				}
			}
			else {
			my @newSource = grep {/$sourceData/i} @{$config_options->{names}};
				$sourceData=$newSource[0] if $newSource[0] ne '';
				# check to make sure image file actually exists.  Otherwise Alert user and read xc:none
				if (-e $sourceData) {
    			$temp->Read($sourceData);
				}
				else {
					Logger($config_options,"I could not find $sourceData","CRIT") unless $sourceData =~ /NONE/;
					$temp->Read('xc:none');
				}
			}
			$temp->Resize(width=>$token->attr->{Width}, height=>$token->attr->{Height}) ;
		}
	
		# because we are stream parsing the xml data we need to remember where on the canvas to composite this image
		my $composite_x=$token->attr->{X};
		my $composite_y=$token->attr->{Y};
		while( defined( $token = $parser->get_token() ) ){
			if ( ($token->is_tag) && ($token->is_end_tag) && ($token->tag =~ /ImageElement/) ) {
			 	last;
			}
			elsif ($token->tag =~ /Actions/ ) {
				# start applying effects to the image.
				while( defined( $token = $parser->get_token() ) ){
					if ( ($token->tag =~ /Crop/) && ($token->is_start_tag)  ) { 
						Logger($config_options,"Cropping $sourceData","DEBUG");
						$temp->Crop(width=>$token->attr->{Width},  
							height=>$token->attr->{Height},  
							x=>$token->attr->{X},  
							y=>$token->attr->{Y} );
					}
					elsif ( ($token->tag =~ /GlassTable/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Glasstabling $sourceData","DEBUG");
						$temp=GlassTable($config_options,$temp,
							$token->attr->{ReflectionLocationX},
							$token->attr->{ReflectionLocationY},
							$token->attr->{ReflectionOpacity}, 
							$token->attr->{ReflectionPercentage});
					}
					elsif ( ($token->tag =~ /Glow/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Glow $sourceData ","DEBUG");
						$temp=Glow($config_options,$temp,
							$token->attr->{Color},
							$token->attr->{Opacity},
							$token->attr->{Softness});
					}		
					elsif ( ($token->tag =~ /GaussianBlur/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Applying GaussianBlur to $sourceData","DEBUG");
						$temp->Blur(sigma=>$token->attr->{Radius},radius=>3*$token->attr->{Radius});
					}		
					elsif ( ($token->tag =~ /AdjustHue/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Adjusting Hue for $sourceData","DEBUG");
						$temp->Modulate(hue=>$token->attr->{Angle});
					}		
					elsif ( ($token->tag =~ /AdjustGamma/i) && ($token->is_start_tag)  ) {
						my $gamma=($token->attr->{Gamma}/100)+1;
						Logger($config_options,"Adjusting Gamma for $sourceData to $gamma ","DEBUG");
						$temp->Gamma(gamma=>$gamma);
					}		
					elsif ( ($token->tag =~ /AdjustOpacity/i) && ($token->is_start_tag)  ) {
						my $opacity_percent=($token->attr->{Opacity}/100);
						Logger($config_options,"Adjusting Opacity $sourceData by $opacity_percent","DEBUG");
						$temp=AdjustOpacity($config_options,$temp,$opacity_percent);
					}		
					elsif ( ($token->tag =~ /RoundCorners/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Rounding Corners $sourceData","DEBUG");
       			$temp=RoundCorners($config_options,$temp,
       				$token->attr->{BorderColor},
       				$token->attr->{BorderWidth},
       				$token->attr->{Roundness},
       				$token->attr->{Corners});
					}
					elsif ( ($token->tag =~ /AdjustSaturation/i) && ($token->is_start_tag)  ) {
						my $level=($token->attr->{Level} * 255)/100; # imagemagick saturation is range 0-255 
						Logger($config_options,"Adjusting Saturation level $level $sourceData","DEBUG");
						$temp->Modulate(saturation=>$level );
					}
					elsif ( ($token->tag =~ /AdjustBrightness/i) && ($token->is_start_tag)  ) {
						my $level=($token->attr->{Level} * 255)/100; # imagemagick brightness is range 0-255 
						Logger($config_options,"Adjusting brightness level $level $sourceData","DEBUG");
						$temp->Modulate(brightness=>$level );
					}
					elsif ( ($token->tag =~ /PerspectiveView/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Adjusting PerspectiveView $sourceData","DEBUG");
						$temp=PerspectiveView($config_options,$temp,
							$token->attr->{Angle},
							$token->attr->{Orientation}
						);	
					}
					elsif ( ($token->tag =~ /Rotate/i) && ($token->is_start_tag)  ) {
						my $degrees=$token->attr->{Angle} * (-1);
						Logger($config_options,"Rotating $sourceData by $degrees degrees","DEBUG");
						my ($width, $height) = $temp->Get('columns', 'rows');
       			my @points=split(/[ ,]+/,sprintf("0,%d 100 %d",$height,$degrees));
						$temp->Distort(method=>'ScaleRotateTranslate','best-fit'=>'False','virtual-pixel'=>'transparent',points=>\@points);
					}
					elsif ( ($token->tag =~ /DropShadow/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Adding Shadow to $sourceData","DEBUG");
						$temp=DropShadow($config_options,$temp,
							$token->attr->{Angle},
							$token->attr->{Color},
							$token->attr->{Distance},
							$token->attr->{Opacity},
							$token->attr->{Softness}
						);
					}
					elsif ( ($token->tag =~ /Skew/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Skewing $sourceData","DEBUG");
						$temp=Skew($config_options,$temp,
						$token->attr->{Angle},
						$token->attr->{ConstrainProportions},
						$token->attr->{Orientation}, 
						$token->attr->{Type});
					}
					elsif ( ($token->tag =~ /Flip/i) && ($token->is_start_tag)  ) {
						Logger($config_options,"Flipping/Flopping $sourceData","DEBUG");
						if ( $token->attr->{Type} =~ /Horizontal/i ) { 
							$temp->Flip();
						}
						else {
							$temp->Flop();
						}
					}
					else {
						if ( ( $token->tag ) && ( $token->is_start_tag ) ) {
							Logger($config_options,"don't know what to do with Image Element " . $token->tag ,"CRIT");
						}
					}
					last if ( ($token->tag =~ /Actions/) );
				} # end inner while
			} # end Action If
		} # end While
	
#$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
		$temp->Set(alpha=>'');
		$base_image->Composite(image=>$temp, compose=>'src-over', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
		undef $temp;
}

#---------------------------------------------------------------------------------------------
#
# Text Element Functions
#
#---------------------------------------------------------------------------------------------

sub ParseFont {
# take a Font string and return a hash
# Font Styles
# ImageDraw Font objects can be set so they look bold, italic, underline, and strikeout. 
# Font Size and Unit
# The font size value will depend on the font unit which can be set to Point, Inch, Millimeter, or Pixel. 

	my $config_options=shift;
	my $font=shift;

	Logger($config_options,"Font Request -> $font","DEBUG");

	# is this a basic font line or one with bold/italic/underline/strikeout
	my @font_ary=split(/,/,$font);

	# do we know about this font?

	my %font_hash=(
			'Family'		=>	"$font_ary[0]",
			'Size'			=>	$font_ary[1],
			'Unit'			=>	scalar(@font_ary) > 5 ?	$font_ary[6] : $font_ary[2],
	);

	# Check for the existence of this Font

	my $temp=Image::Magick->new();
	my @fonts=$temp->QueryFont($font_hash{Family});

	Logger($config_options,"This font is not found ---- $font_hash{Family}","CRIT") unless defined ($fonts[0]);
	undef $temp;

	unless (-e $fonts[10] ) {
		Logger($config_options,"This glyph file is not found $fonts[10].  Please ensure your fonts are set up correctly.","CRIT");
	}

	my $font_string=Dumper(\@fonts);
	Logger($config_options,"Results of QueryFont @fonts","DEBUG");

	if (scalar(@font_ary) > 5) {
		# build a string of which ever text options are specified
		my @options;
		push (@options, 'Italic') 		if $font_ary[3] =~ /True/i;

		$font_hash{Options}=join(',',@options);
		$font_hash{Family}.="-Bold" if $font_ary[2] =~ /True/i;
	}

	my $tmp_string=Dumper(\%font_hash);
	Logger($config_options,$tmp_string,"DEBUG");

	return \%font_hash;
}

sub GetGravity {
# ImageDraw alignment options, The text can be left-aligned, center-aligned, or right-aligned in both vertical and horizontal directions. 
	my $config_options=shift;
	my $alignment=shift;

	my %alignment_hash = (
			'TopLeft'				=>	'NorthWest',
			'TopCenter'			=>	'North',
			'TopRight'			=>	'NorthEast',
			'Left'					=>	'West',
			'Right'					=>	'East',
			'MiddleLeft'		=>	'West',
			'MiddleRight'		=>	'East',
			'BottomLeft'		=>	'SouthWest',
			'BottomMiddle'	=>	'South',
			'BottomRight'		=>	'SouthEast',
			'MiddleCenter'	=>	'Center',
		);

	Logger($config_options,"Translating Alignment orig->$alignment result->$alignment_hash{$alignment}","DEBUG");
	return $alignment_hash{$alignment};
}
	

sub AddTextElement {
# Two basic types of text elements;
# 1) those with effect i.e. Action
# 2) those without

	my $config_options=shift;
	my $provider_hash=shift;
	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $template_xml=shift;
	my $sourceData;
	my $string;

	my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
	my $temp=Image::Magick->new(magick=>'png');
	$temp->Set( size=>sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height}) );
	$temp->Read('xc:none');

	# because we are stream parsing the xml data we need to remember where on the canvas to composite this image
	my $composite_x=$token->attr->{X};
	my $composite_y=$token->attr->{Y};

	# create the text element image contents
	my $forecolor=GetColor($config_options,$token->attr->{ForeColor});
	my $font_hash=ParseFont($config_options,$token->attr->{Font});
	my $gravity=GetGravity($config_options,$token->attr->{TextAlignment} );

	$string=$token->attr->{Text};
	if ($string =~ /\%.+\%/) {
		DeTokenize($config_options,\$string,$provider_hash,$template_xml);
	}

	Logger($config_options,"Font Family=$font_hash->{Family}\tsize=$font_hash->{Size}","DEBUG");
	my @text_attributes=$temp->QueryFontMetrics(text=>$string, fill=>$forecolor, font=>$font_hash->{Family}, pointsize=>$font_hash->{Size} ,antialias=>'True', gravity=>$gravity);
	if ($text_attributes[4] > $token->attr->{Width} ) {
		# time to wrap some text
		$string=TextWrap($config_options,$string, $token->attr->{Width}, $font_hash->{Family}, $font_hash->{Size})
	}

	if ($token->attr->{AutoSize} =~ /true/i  ) {$gravity = 'West';}

	my %text_attributes=(
			text			=> $string,
			fill			=> $forecolor,
			font			=> $font_hash->{Family},
			pointsize	=> $font_hash->{Size},
			antialias	=> 'true',
			gravity		=> $gravity,
			stretch		=> 'Expanded',
			);

	if ($token->attr->{StrokeWidth} > 0) {
		$text_attributes{strokewidth} = $token->attr->{StrokeWidth};
		if (GetColor($config_options,$token->attr->{StrokeColor}) !~ /000000/ ) {
			$text_attributes{stroke} = GetColor($config_options,$token->attr->{StrokeColor});
		}
	}

	$temp->Annotate(%text_attributes);

	while( defined( $token = $parser->get_token() ) ){
		if ( ($token->is_tag) && ($token->is_end_tag) && ($token->tag =~ /TextElement/) ) {
	 		last;
		}
		elsif ($token->tag =~ /Actions/ ) {
			while( defined( $token = $parser->get_token() ) ){
			# start applying effects to the image.
				if ( ($token->tag =~ /DropShadow/i) && ($token->is_start_tag)  ) {
					Logger($config_options,"Adding Shadow to $string","DEBUG");
						$temp=DropShadow($config_options,$temp,
							$token->attr->{Angle},
							$token->attr->{Color},
							$token->attr->{Distance},
							$token->attr->{Opacity},
							$token->attr->{Softness}
						);
				}
				elsif ( ($token->tag =~ /GlassTable/i) && ($token->is_start_tag)  ) {
					Logger($config_options,"Glasstabling $sourceData","DEBUG");
					$temp=GlassTable($config_options,$temp,
						$token->attr->{ReflectionLocationX},
						$token->attr->{ReflectionLocationY},
						$token->attr->{ReflectionOpacity}, 
						$token->attr->{ReflectionPercentage});
				}
				elsif ( ($token->tag =~ /Stretch/i) && ($token->is_start_tag) ) {
					Logger($config_options,"Stretching $sourceData","DEBUG");
					$temp->Scale(height=>$token->attr->{Height}, width=>$token->attr->{Width} );
				}
				elsif ( ( $token->tag ) && ( $token->is_start_tag ) ) {
					Logger($config_options,"don't know what to do with Text Element ".$token->tag ,"CRIT");
				}
				last if ( ($token->tag =~ /Actions/) );
			} # end  inner While
		} # end if
	} # end outer While
	
	$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
	undef $temp;
}

sub TextWrap {
# wrap some text
	my $config_options=shift;
	my $string=shift;
	my $image_width=shift;
	my $family=shift;
	my $point=shift;

# the logic I am working with is render an image add text get metrics see if it fits
# rinse and repeat

	my $temp_img=Image::Magick->new(magick=>'png');
	my $new_text;
	my $running_text="";

	Logger($config_options,"Text Wrap before ->".$string,"DEBUG");

	$string =~ /^(\s+)\S/;
	my $indent=$1;
	my @ary=split(/\s/,$string);
	my $first=1;

	foreach my $word (@ary) {
		next if ( ($word eq '') && ($first == 1) );
  	$temp_img->Set(size=>sprintf("%dx100",$image_width));
  	$temp_img->Read('xc:none');
		if ( (length ($running_text) == 0) && (length ($indent) >0) ) {
			$running_text=$indent;
  		$temp_img->Annotate(text=>$running_text.$word,font=>$family,pointsize=>$point);
		}
		else {
  		$temp_img->Annotate(text=>"$running_text $word",font=>$family,pointsize=>$point);
		}
		if (($temp_img->QueryFontMetrics(text=>"$running_text $word",font=>$family,pointsize=>$point))[4] < $image_width ) {
			if ($first == 1) {
  			$running_text=$running_text.$word;
				$first=0;
			}
			else{
  			$running_text="$running_text $word";
			}
		}
		else {
			$new_text.="$running_text\n";
			$running_text=$word;
		}
  	@$temp_img=();
	}
	$new_text.="$running_text\n";

	Logger($config_options,"Text Wrap after  ->".$new_text,"DEBUG");
			
	return $new_text;
}

#---------------------------------------------------------------------------------------------
#
# Movie Sheet Generation
#
#---------------------------------------------------------------------------------------------

sub DeTokenize {
# convert the template %TOKEN% tokens to their actual value
# this requires the mediainfo hash and the moviedb xml
	my $config_options=shift;
	my $string=shift;  # the string where I replace the token
	my $provider_hash=shift;
	my $template_xml=shift;

	return 1 unless ($$string =~ /%/) ;

	Logger($config_options,"Detokenizing $$string","DEBUG");

	if ($$string =~ /\%COUNTRIES\%/ ) {
		$$string =~ s/\%COUNTRIES\%/$provider_hash->{COUNTRIES}/;
	}

	if ($$string =~ /\%RUNTIME\%/ ) {
		$$string =~ s/\%RUNTIME\%/$provider_hash->{RUNTIME}/;
	}

	if ($$string =~ /\%RELEASEDATE\%/ ) {
		$$string =~ s/\%RELEASEDATE\%/$provider_hash->{RELEASEDATE}/;
	}

	if ($$string =~ /\%CERTIFICATION\%/ ) {
		$$string =~ s/\%CERTIFICATION\%/$provider_hash->{CERTIFICATION}/;
	}

	if ($$string =~ /\%CERTIFICATIONTEXT\%/ ) {
		$$string =~ s/\%CERTIFICATIONTEXT\%/$provider_hash->{CERTIFICATION}/;
	}

	if ($$string =~ /\%YEAR\%/ ) {
		$$string =~ s/\%YEAR\%/$provider_hash->{YEAR}/;
	}

	if ($$string =~ /\%MPAA\%/ ) {
		$$string =~ s/\%MPAA\%/$provider_hash->{MPAA}/;
	}

	if ($$string =~ /\%EXTERNALSUBTITLES(\d)\%/ ) {
		$$string =~ s/\%EXTERNALSUBTITLES$1\%/NONE/;
	}

	if ($$string =~ /\%EXTERNALSUBTITLESTEXT\%/ ) {
		$$string =~ s/\%EXTERNALSUBTITLESTEXT\%//;
	}

	if ($$string =~ /\%EXTERNALSUBTITLES\%/ ) {
		$$string =~ s/\%EXTERNALSUBTITLES\%/NONE/;
	}

	if ($$string =~ /\%SUBTITLES(\d)\%/ ) {
		my $rep= ( $provider_hash->{"SUBTITLES$1"} ne "" ? $provider_hash->{"SUBTITLES$1"} : "NONE");	
		$$string =~ s/\%SUBTITLES$1\%/$rep/;
	}


	if ($$string =~ /\%.*TITLE\%/ ) {
		$$string =~ s/\%.*TITLE\%/$provider_hash->{TITLE}/;
		if ( $$string =~ /\{(.+)\}/ ) {
			if ( $1 eq "UPPER" ) {
				$$string=uc($$string);
				$$string =~ s/\{UPPER\}//;
			}
			elsif ( $1 eq "LOWER" ) {
				$$string=lc($$string);
				$$string =~ s/\{LOWER\}//;
			}
			elsif ( $1 eq "TITLECASE" ) {
				$$string=ucfirst($$string);
				$$string =~ s/\{TITLECASE\}//;
			}
			else {
				Logger($config_options,"I have found a text modifier I don't recognize -- $1?","CRIT");
			}
		}
	}

	if ($$string =~ /\%DURATIONTEXT\%/) {
		$$string =~ s/\%DURATIONTEXT\%/$provider_hash->{DURATIONTEXT}/;
	}
	
	if ($$string =~ /\%VIDEORESOLUTIONTEXT\%/) {
		$$string =~ s/\%VIDEORESOLUTIONTEXT\%/$provider_hash->{VIDEORESOLUTIONTEXT}/;
	}
	
	if ($$string =~ /\%FRAMERATETEXT\%/) {
		$$string =~ s/\%FRAMERATETEXT\%/$provider_hash->{FRAMERATETEXT}/;
	}

	if ($$string =~ /\%AUDIOCODECTEXT\%/) {
		$$string =~ s/\%AUDIOCODECTEXT\%/$provider_hash->{AUDIOCODECTEXT}/;
	}

	if ($$string =~ /\%ASPECTRATIOTEXT\%/) {
		$$string =~ s/\%ASPECTRATIOTEXT\%/$provider_hash->{ASPECTRATIOTEXT}/;
	}

	if ($$string =~ /\%VIDEOBITRATETEXT\%/) {
		$$string =~ s/\%VIDEOBITRATETEXT\%/$provider_hash->{VIDEOBITRATETEXT}/;
	}

	if ($$string =~ /\%AUDIOCHANNELSTEXT\%/) {
		$$string =~ s/\%AUDIOCHANNELSTEXT\%/$provider_hash->{AUDIOCHANNELSTEXT}/;
	}

	if ($$string =~ /\%AUDIOBITRATETEXT\%/) {
		$$string =~ s/\%AUDIOBITRATETEXT\%/$provider_hash->{AUDIOBITRATETEXT}/;
	}

	if ($$string =~ /\%FILESIZETEXT\%/) {
		$$string =~ s/\%FILESIZETEXT\%/$provider_hash->{FILESIZETEXT}/;
	}

	if ($$string =~ /\%RATING\%/ ) {
		$$string =~ s/\%RATING\%/$provider_hash->{RATING}/;
	}

	if ($$string =~ /\%PLOT\%/ ) {
		$$string =~ s/\%PLOT\%/$provider_hash->{PLOT}/;
	}

	if ($$string =~ /\%STUDIOS\%/ ) {
		$$string =~ s/\%STUDIOS\%/$provider_hash->{STUDIOS}/;
	}
    
  if ( $$string =~ /\%FANART1\%/ ) {
    $$string =~ s/\%FANART1\%/$provider_hash->{FANART1}/;
		Logger($config_options,"Grabbing FANART1 $provider_hash->{FANART1}","DEBUG");
	}

  if ( $$string =~ /\%FANART2\%/ ) {
    $$string =~ s/\%FANART2\%/$provider_hash->{FANART2}/;
		Logger($config_options,"Grabbing FANART2 $provider_hash->{FANART2}","DEBUG");
	}

  if ( $$string =~ /\%FANART3\%/ ) {
    $$string =~ s/\%FANART3\%/$provider_hash->{FANART3}/;
		Logger($config_options,"Grabbing FANART3 $provider_hash->{FANART3}","DEBUG");
	}
    
  if ( $$string =~ /\%BACKGROUND\%/ ) {
    $$string =~ s/\%BACKGROUND\%/$provider_hash->{BACKGROUND}/;
	}

  if ( $$string =~ /\%COVER\%/ ) {
		Logger($config_options,"Requested Cover is $provider_hash->{COVER}","DEBUG");
    $$string =~ s/\%COVER\%/$provider_hash->{COVER}/;
  }

	if ($$string =~ /\%VIDEOFORMAT\%/ ) {
		my $rep="";
		foreach (@{$template_xml->{Template}->{VideoFormats}->{VideoFormat} }) {
			$rep = $_->{Image}->{value} if $provider_hash->{VIDEOFORMAT} =~  /$_->{Text}->{value}/i;
		}
		Logger($config_options,"VIDEOFORMAT $provider_hash->{VIDEOFORMAT} resolves to $rep","DEBUG");
		$$string =~ s/\%VIDEOFORMAT\%/$rep/;
	}

	if ($$string =~ /\%CONTAINERTEXT\%/ ) {
		$$string =~ s/\%CONTAINERTEXT\%/$provider_hash->{CONTAINERTEXT}/;
	}

	if ($$string =~ /\%VIDEOCODECTEXT\%/ ) {
		$$string =~ s/\%VIDEOCODECTEXT\%/$provider_hash->{VIDEOCODECTEXT}/;
	}

	if ($$string =~ /\%MEDIAFORMATTEXT\%/ ) {
		$$string =~ s/\%MEDIAFORMATTEXT\%/$provider_hash->{MEDIAFORMATTEXT}/;
	}

	if ($$string =~ /\%MEDIAFORMAT\%/ ) {
		$$string =~ s/\%MEDIAFORMAT\%/$provider_hash->{MEDIAFORMAT}/;
	}

	if ($$string =~ /\%RESOLUTION\%/ ) {
		my $rep="";
		foreach (@{$template_xml->{Template}->{Resolutions}->{Resolution} }) {
			$rep = $_->{Image}->{value} if $provider_hash->{RESOLUTION} =~  /$_->{Text}->{value}/i;
		}
		Logger($config_options,"RESOLUTION $provider_hash->{RESOLUTION} resolves to $rep","DEBUG");
		$$string =~ s/\%RESOLUTION\%/$rep/;
	}

	if ($$string =~ /\%SOUNDFORMAT\%/ ) {
		my $rep="";
		foreach (@{$template_xml->{Template}->{SoundFormats}->{SoundFormat} }) {
			$rep = $_->{Image}->{value} if $provider_hash->{SOUNDFORMAT} =~  /$_->{Name}->{value}/i;
		}
		Logger($config_options,"SOUNDFORMAT $provider_hash->{SOUNDFORMAT} resolves to $rep","DEBUG");
		$$string =~ s/\%SOUNDFORMAT\%/$rep/;
	}

	if ($$string =~ /\%SUBTITLESTEXT\%/ ) {
		my @subs=@{$provider_hash->{SUBTITLES}};

		# truncate the array if necessary
		$#subs=4 if $#subs>4;
		$$string =~ s/\%SUBTITLESTEXT\%/@subs/;
	}

	if ($$string =~ /\%SUBTITLES\%/ ) {
		my @subs=@{$provider_hash->{SUBTITLES}};

		my $max=$template_xml->{Template}->{Settings}->{Subtitles}->{MaximumValues}->{value};
		my $join_char=$template_xml->{Template}->{Settings}->{Subtitles}->{Separator}->{value};

		# truncate the array if necessary
		$#subs=($max-1) if $#subs>$max;
		my $rep=join($join_char,@subs);
		$$string =~ s/\%SUBTITLES\%/$rep/;
	}

	if ($$string =~ /\%ACTORS\%/ ) {
		my @actors=@{$provider_hash->{ACTORS}};

		# we have an array of every director in this movie.  the template defines a max and a join character
		my $max=$template_xml->{Template}->{Settings}->{Actors}->{MaximumValues}->{value};
		my $join_char=$template_xml->{Template}->{Settings}->{Actors}->{Separator}->{value};
#if ($join_char =~ /   /) {$join_char="\\n";}

		# truncate the array if necessary
		$#actors=($max-1) if $#actors>$max;
		my $rep=join($join_char,@actors);
		$$string =~ s/\%ACTORS\%/$rep/;
	}

	if ($$string =~ /\%DIRECTORS\%/ ) {
		my @directors=@{$provider_hash->{DIRECTORS}};
		
		# we have an array of every director in this movie.  the template defines a max and a join character
		my $max=$template_xml->{Template}->{Settings}->{Directors}->{MaximumValues}->{value};
		my $join_char=$template_xml->{Template}->{Settings}->{Directors}->{Separator}->{value};

		# truncate the array if necessary
		$#directors=($max-1) if $#directors>$max;

		my $rep=join($join_char,@directors);
		$$string =~ s/\%DIRECTORS\%/$rep/;
	}

	if ($$string =~ /\%GENRES\%/ ) {
		my @genres=@{$provider_hash->{GENRES}};

    # we have an array of every genre type.  the template defines a max and a join character
    my $max=$template_xml->{Template}->{Settings}->{Genres}->{MaximumValues}->{value};
    my $join_char=$template_xml->{Template}->{Settings}->{Genres}->{Separator}->{value};

    # truncate the array if necessary
    $#genres=($max-1) if $#genres>$max;

    my $rep=join($join_char,@genres);
    $$string =~ s/\%GENRES\%/$rep/;
	}


	if ( $$string =~ /\%PATH\%/ ) {
		# fix the source, it will come in Window Path Format, switch it to Unix
		$$string =~ s/\%PATH\%/$config_options->{PATH}/;
		$$string =~ tr |\\|/|;
		Logger($config_options,"Path expanded -> $$string","DEBUG");
	}

	if ($$string =~ /\%.+\%/ ) {
		# add some color so this stands out
		Logger($config_options,"Unable to Detokenize -> $$string","ERROR");
		return 0;
	} 
	return 1;

}

sub grab_thumbnail {
# grab a thumbnail image for the movie
	my $provider_hash=shift;
	my $thumbnail;

	$thumbnail=Image::Magick->new(magick=>'png');
	$thumbnail->Read($provider_hash->{COVER});

	return $thumbnail;
}

sub generate_moviesheet {
# takes as input a movie data hash, a template file and the filenamed array
	my $config_options=shift;
	my $provider_hash=shift;

	my $parser = XML::TokeParser->new( $config_options->{TEMPLATE} );
	my $template_obj = new XML::Bare(file => $config_options->{TEMPLATE} );
	my $template_xml=$template_obj->parse();

	my $moviesheet;

	while( defined( my $token = $parser->get_token() ) ){
    if ( ($token->tag =~ /ImageDrawTemplate/ ) && ($token->is_start_tag) ) {
     	Logger($config_options,"Starting Moviesheet Generation","DEBUG");
    }

    if ( ($token->tag eq "Canvas") && ($token->is_start_tag) ) {
     	my $msg=sprintf("create a canvas of width=%d and height=%d",$token->attr->{Width},$token->attr->{Height});
		 	Logger($config_options,$msg,"DEBUG");
		# Create a Canvas
		my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
		$moviesheet=Image::Magick->new(size=>$geometry,magick=>'png'); # invoke new image
		$moviesheet->ReadImage('xc:black'); # make a white canvas
    }

		# add an image element to the canvas
    if ( ($token->tag eq "ImageElement") && ($token->is_start_tag)  ) {
      Logger($config_options,"ImageElement ".$token->attr->{Name},"DEBUG");
			AddImageElement($config_options,$provider_hash,$moviesheet,$token,$parser,$template_xml);
    }

		# add a text element to the canvas
    if ( ($token->tag eq "TextElement") && ($token->is_start_tag)  ) {
      Logger($config_options,"TextElement ".$token->attr->{Name},"DEBUG");
			AddTextElement($config_options,$provider_hash,$moviesheet,$token,$parser,$template_xml);
    }
	}
	return $moviesheet;
}

#---------------------------------------------------------------------------------------------
#
# Movie Info and MediaInfo Function
#
#---------------------------------------------------------------------------------------------


sub trim {
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub clean_name {
# shamelessly stolen from myth code for scraping movie meta data
# Give the filename a more meaningful  name
	my $movie_name = shift;

	$movie_name =~ s/\.\w+$//; # the extension
	$movie_name =~ s/^\d+(\.|_|-|\s)//; # track number?
	$movie_name =~ s/\[\d{4}\](.*)$//; # sometimes videos include "[2008]"
	$movie_name =~ s/[\[,\(,\{]\d{4}[\],\),\}]//; #remove year
	$movie_name =~ s/_\d{4}.*$//; #remove year and everything after in
	$movie_name =~ s/\.\d{4}.*$//; #remove year and everything after in
	$movie_name =~ tr/[\.\_\-\[\]!\(\)\:]/ /; # turn delimeter characters into spaces

	$movie_name =~ s/\s+/ /g; # convert n-whitespaces into a single whitespace
	$movie_name =~ tr/[A-Z]/[a-z]/; # change movie name to lower case
	$movie_name =~ s/\s(xvid|divx|h264|x264|ac3|mpg)(.*)$//g; # remove codecs - and everything after
	$movie_name =~ s/\s(internal|repack|proper|fixed|read nfo|readnfo|unrated|widescreen)(.*)$//g;# remove notes - and everything after
	$movie_name =~ s/\s(dvdrip|screener|hdtv|dsrip|dsr|dvd|bluray|blueray|720p|hr|workprint)(.*)$//g;# remove sources - and every thing after
	$movie_name =~ s/\s(klaxxon|axxo)//g;# remove distributors

	# Part removal enhancement by Laurie Odgers
	# Remove anything after "part", "cd", "ep" or "webisode"
	$movie_name =~ s/((part|cd|ep|webisode)[\s]+\d+)(.*)$//g;	  # Numbering, matches: part 1, cd.1, ep1
	# Roman Numerals, matches: part I, cd.V, webisodeX
	$movie_name =~ s/((part|cd|ep|webisode)[\s]+[i,v,x]+[\s])(.*)$//g;      # Matches "moviename - part i [DivX]"
	$movie_name =~ s/((part|cd|ep|webisode)[\s]+[i,v,x]+$)(.*)$//g; # Matches "moviename - part i"

	$movie_name = trim($movie_name);

	return $movie_name;
}

sub Interactive {
# present the user with a selection of which movie is correct.
	my $config_options=shift;
	my $xml_root=shift;
	my $file_name=shift;

	my %menu;

  foreach (@{ $xml_root->{OpenSearchDescription}->{movies}->{movie} } ) {
			my $key=sprintf("%s -- %s",$_->{name} ,$_->{overview});
			$key= decode_entities($key);
			$menu{substr($key,0,90)}=$_->{id} unless ($key eq '');
			my $count= keys %menu;
			last if $count == 26;
  }

	prompt ("\nPlease identify which movie entry $file_name is:", -menu=>\%menu);
	return $_;
}


sub GetTmdbID {
# passed in the file name, clean it and return the tmdb_id
	my $config_options=shift;
	my $provider_hash = shift;
	my $tmdb_id;
	
	if ($provider_hash->{MOVIEFILENAME} =~ /tmdb_id=(.*)\..*$/) {
		return ($1);
	}

	# the file name does not contain the tmdb_id.  so let's query tmdb's api and get the filename
	# N.B. here would be a possible injection point to allow the user to select a specific movie should
	# the results from tmdb's api have multiple hits.
	my $movie_name=clean_name($provider_hash->{MOVIEFILENAME});
	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->env_proxy;

	my $url;
	
	if (defined $provider_hash->{IMDB_ID} ) {
		$url="http://api.themoviedb.org/2.1/Movie.imdbLookup/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/".$provider_hash->{IMDB_ID};
	}
	else {
		$url="http://api.themoviedb.org/2.1/Movie.search/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/$movie_name";
	}

	Logger($config_options,$url,"DEBUG");
	my $response = $ua->get($url);
	my $xml_ob = new XML::Bare(text => $response->decoded_content );
	my $xml_root=$xml_ob->simple();

	if ( $xml_root->{OpenSearchDescription}->{'opensearch:totalResults'} > 1 ) {
		Logger($config_options,"Multiple movie entries found for $movie_name\n\tthis can be fixed by adding the string tmdb_id=<the ID> to the filename\n\ti.e. 21.avi becomes 21tmdb=8065.avi to ensure we get the Kevin Spacey one\n\tOr by running the script with the -i option for interactive.","WARN");
		# go interactive if the flag is set
		if ($config_options->{INTERACTIVE} ) {
			$tmdb_id=Interactive($config_options, $xml_root, $provider_hash->{MOVIEFILENAME});
		}
		else {
			$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->[0]->{id};
		}
	}
	elsif ($xml_root->{OpenSearchDescription}->{'opensearch:totalResults'} == 1) {
		$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->{id};
	}
	else {
		Logger ($config_options,"I was unable to find any information for $movie_name","DEBUG");
	}

	Logger($config_options,"Found tmdb_id='$tmdb_id'","DEBUG");
	return $tmdb_id;
}	

sub GetMediaDetails_moviemeter {
# grab the xml data for this specific movie from moviemeter
  my $config_options=shift;
  my $provider_hash=shift;

	my $API_key="szgh9aryd1a45ezhs97fk65zjr05tc17";
	my $client= XML::RPC->new('http://www.moviemeter.nl/ws');

	my $session = $client->call("api.startSession", $API_key);
	my $moviemeterID = $client->call("film.retrieveByImdb",$session->{session_key},$provider_hash->{IMDB_ID});

	my $movie_result = $client->call("film.retrieveDetails",$session->{session_key},$moviemeterID);

  my @directors=map {$_->{name}} @{$movie_result->{directors} };
  my @cast=map {$_->{name}} @{$movie_result->{actors} } ;

  # provider_hash hash

  $provider_hash->{TITLE}= $movie_result->{title};
  $provider_hash->{ORIGINALTITLE}= $movie_result->{alternative_titles}[0];
  $provider_hash->{PLOT}= $movie_result->{plot};
  $provider_hash->{YEAR}= $movie_result->{year};
  $provider_hash->{ACTORS}= \@cast;
  $provider_hash->{GENRES}= $movie_result->{genres};
  $provider_hash->{DIRECTORS}= \@directors;
  $provider_hash->{COUNTRIES}= $movie_result->{countries}->[0]->{iso_3166_1};
  $provider_hash->{RELEASEDATE}= $movie_result->{dates_cinema}->[0]->{date};
}

sub GetMediaDetails_tgmd {
# parse a tgmd file
	my $config_options=shift;
	my $provider_hash=shift;

	my $tempdir="/var/tmp/$$";
	mkdir $tempdir;

	$provider_hash->{TGMD_TEMPDIR}=$tempdir;

	system ("unzip -d $tempdir '$provider_hash->{TGMD_FILE}' >/dev/null 2>&1");

	# read in the details
	# NFO has the goods on the xml

	my $tgmd_obj = new XML::Bare(file => "$tempdir/NFO" );
	my $tgmd_xml = $tgmd_obj->simple();
	my @directors;
	if (ref $tgmd_xml->{movie}->{director}->{name} =~ /array/i ) {
		@directors=$tgmd_xml->{movie}->{director}->{name};
	}
	else {
		push (@directors, $tgmd_xml->{movie}->{director}->{name} );
	}

	$provider_hash->{TITLE}= $tgmd_xml->{movie}->{title};
 	$provider_hash->{ORIGINALTITLE}= $tgmd_xml->{movie}->{originaltitle};
 	$provider_hash->{PLOT}= $tgmd_xml->{movie}->{plot};
 	$provider_hash->{YEAR}= $tgmd_xml->{movie}->{year};
 	$provider_hash->{ACTORS}= $tgmd_xml->{movie}->{actor}->{name};
 	$provider_hash->{GENRES}= $tgmd_xml->{movie}->{genre}->{name};
 	$provider_hash->{DIRECTORS}= \@directors;
 	$provider_hash->{COUNTRY}= $tgmd_xml->{movie}->{country}->{name};
 	$provider_hash->{STUDIOS}= ref ($tgmd_xml->{movie}->{studio}->{name}) =~ /array/i ? $tgmd_xml->{movie}->{studio}->{name}->[0] : $tgmd_xml->{movie}->{studio}->{name};
 	$provider_hash->{RATING}= $tgmd_xml->{movie}->{rating};
 	$provider_hash->{CERTIFICATION}= $tgmd_xml->{movie}->{certification};
 	$provider_hash->{RELEASEDATE}= $tgmd_xml->{movie}->{releasedate};
 	if (-e "$tempdir/BACKGROUND" ) { $provider_hash->{BACKGROUND}="$tempdir/BACKGROUND"; }
 	if (-e "$tempdir/FANART1" ) { $provider_hash->{FANART1}="$tempdir/FANART1"; }
 	if (-e "$tempdir/FANART2" ) { $provider_hash->{FANART2}="$tempdir/FANART2"; }
 	if (-e "$tempdir/FANART3" ) { $provider_hash->{FANART3}="$tempdir/FANART3"; }
 	if (-e "$tempdir/COVER" ) { $provider_hash->{COVER}="$tempdir/COVER"; }

	my $tgmd_string=Dumper($tgmd_xml);
	Logger($config_options,"TGMD Data","DEBUG");
	Logger($config_options,$tgmd_string,"DEBUG");

}


sub GetMediaDetails_imdb {
# grab the xml data for this specific movie from imdb
	my $config_options=shift;
	my $provider_hash=shift;
	
	my $movie = new IMDB::Film(crit => $provider_hash->{IMDB_ID});
	
	my %release=map{$_->{country} => $_->{date}} @{$movie->release_dates()};
	my @cert = $movie->certifications();
	my @directors=map {$_->{name}} @{$movie->directors()};
	my @cast=map {$_->{name}} @{$movie->cast()} ;
	my @countries=@{$movie->country()};
	
	# provider_hash hash
	
	$provider_hash->{TITLE}= $movie->title() unless defined $provider_hash->{TITLE};
	$provider_hash->{ORIGINALTITLE}= '' unless defined $provider_hash->{ORIGINALTITLE};
	$provider_hash->{PLOT}= $movie->full_plot() unless defined $provider_hash->{PLOT};
	$provider_hash->{YEAR}= $movie->year() unless defined $provider_hash->{YEAR};
	$provider_hash->{ACTORS}= \@cast unless defined $provider_hash->{ACTORS};
	$provider_hash->{GENRES}= $movie->genres() unless defined $provider_hash->{GENRES};
	$provider_hash->{DIRECTORS}= \@directors unless defined $provider_hash->{DIRECTORS};
	$provider_hash->{MPAA}= $movie->mpaa_info() unless defined $provider_hash->{MPAA};
	$provider_hash->{COUNTRIES}= $countries[0] unless defined $provider_hash->{COUNTRIES};
	$provider_hash->{STUDIOS}= $movie->company() unless defined $provider_hash->{STUDIOS};
	$provider_hash->{RATING}= $movie->rating() unless defined $provider_hash->{RATING};
	$provider_hash->{CERTIFICATION}= $cert[0]->{USA} unless defined $provider_hash->{CERTIFICATION};
	$provider_hash->{RELEASEDATE}= $release{Canada} unless defined $provider_hash->{RELEASEDATE};


}

sub GetMediaDetails_tmdb {
# grab the xml data for this specific movie from themoviedb.org
# tmdb provides imdb id, cover, fanart[1-3], 
	my $config_options=shift;
	my $tmdb_id=shift;
	my $provider_hash=shift;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->env_proxy;

	Logger($config_options,"http://api.themoviedb.org/2.1/Movie.getInfo/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/$tmdb_id","DEBUG");
	my $response = $ua->get("http://api.themoviedb.org/2.1/Movie.getInfo/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/$tmdb_id");
	my $xml_data=decode_entities($response->decoded_content);
	my $xml_ob = new XML::Bare(text => $xml_data );
	my $movie_xml=$xml_ob->parse();

  my @backdrops;
  # grab the backdrop image from themoviedb
  foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
   	push ( @backdrops, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /original/i) && ($_->{type}->{value} =~ /backdrop/i) );
  }
  if (scalar (@backdrops) > 1) {
   	# pick one randomly
   	# $image_url=$backdrops[ rand @backdrops ];
   	$provider_hash->{BACKGROUND}=$backdrops[0] unless defined $provider_hash->{BACKGROUND};
  }
  else {
   	$provider_hash->{BACKGROUND}=$backdrops[0] unless defined $provider_hash->{BACKGROUND};
	}

	$provider_hash->{RELEASEDATE} = $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{released}->{value} unless defined $provider_hash->{RELEASEDATE};

  my @fanart;
  # grab the fanart image from themoviedb
   foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
     push ( @fanart, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /original/i) && ($_->{type}->{value} =~ /backdrop/i) );
   }
	$provider_hash->{FANART1}=$fanart[0] unless defined $provider_hash->{FANART1};
	$provider_hash->{FANART2}=$fanart[1] unless defined $provider_hash->{FANART2};
	$provider_hash->{FANART3}=$fanart[2] unless defined $provider_hash->{FANART3};

  my @covers;
  # grab the cover image from themoviedb
  foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
    push ( @covers, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /mid/i) && ($_->{type}->{value} =~ /poster/i) );
  }
  if (scalar (@covers) > 1) {
    # pick one randomly
    # $image_url=$covers[ rand @covers ];
    $provider_hash->{COVER}=$covers[0] unless defined $provider_hash->{COVER};
  }
  else {
    $provider_hash->{COVER}=$covers[0] unless defined $provider_hash->{COVER};
  }

	$provider_hash->{IMDB_ID}=$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{imdb_id}->{value};
}

sub GetMediaInfo {
# call the shell program mediainfo on $actual_file_name and return a hash reference to it
	my $config_options=shift;
	my $provider_hash=shift;

	# I really hate doing it this way.  At some point it would be great to talk direct to the library
	# some effort should be put into ensuring that $movie_name is safe
	my $cmd=sprintf("mediainfo --Output=XML \"%s\" |",$provider_hash->{FULLMOVIEPATH});
	#open my $FD, "mediainfo --Output=XML '$movie_name' |" or die "unable to open $movie_name";
  open my $FD, $cmd or die "unable to open $provider_hash->{FULLMOVIEPATH}";
  my @xml=<$FD>;
  close $FD;

  my $ob = new XML::Bare(text => "@xml" );

	my $media_info=$ob->simple();

	my $logger_msg=Dumper $media_info;
	Logger($config_options,"Media Info XML Object\n$logger_msg","DEBUG");

	if (ref($media_info->{Mediainfo}->{File}->{track}) eq "ARRAY" )  {
		$provider_hash->{DURATIONTEXT}				= $media_info->{Mediainfo}->{File}->{track}->[1]->{Duration};
		$provider_hash->{FRAMERATETEXT}				= $media_info->{Mediainfo}->{File}->{track}->[1]->{Frame_rate};
		$provider_hash->{FRAMERATETEXT}				=~ s/\w*fps//;
		$provider_hash->{AUDIOCODECTEXT}			= $media_info->{Mediainfo}->{File}->{track}->[2]->{Codec_ID};
		$provider_hash->{ASPECTRATIOTEXT}			= $media_info->{Mediainfo}->{File}->{track}->[1]->{Display_aspect_ratio};
		$provider_hash->{VIDEOBITRATETEXT}		= $media_info->{Mediainfo}->{File}->{track}->[1]->{Bit_rate}; 
		$provider_hash->{AUDIOBITRATETEXT}		= $media_info->{Mediainfo}->{File}->{track}->[2]->{Bit_rate};
		$provider_hash->{FILESIZETEXT}				= $media_info->{Mediainfo}->{File}->{track}->[0]->{File_size};
		$provider_hash->{VIDEORESOLUTIONTEXT}	= sprintf("%sx%s",$media_info->{Mediainfo}->{File}->{track}->[1]->{Width},$media_info->{Mediainfo}->{File}->{track}->[1]->{Height});
		$provider_hash->{VIDEORESOLUTIONTEXT} =~ s/pixels//g;
		$provider_hash->{VIDEORESOLUTIONTEXT} =~ s/\s//g;
		$provider_hash->{AUDIOCHANNELSTEXT}		= $media_info->{Mediainfo}->{File}->{track}->[2]->{Channel_s_};
		$provider_hash->{AUDIOCHANNELSTEXT}		=~ s/(\d+) .*$/$1 /;
		my $runtime=$media_info->{Mediainfo}->{File}->{track}->[0]->{Duration};
		$runtime =~ /(\d+)h\s*(\d+)mn/;
		$provider_hash->{RUNTIME}							= $2+($1*60);
	
		# supported values		Divx, xvid, wmv, avc, mpeg 
		$provider_hash->{VIDEOFORMAT}					= lc($media_info->{Mediainfo}->{File}->{track}->[1]->{Format});
		$provider_hash->{VIDEOFORMAT}					=~ s/mpeg-4 visual/divx/i;

		$provider_hash->{VIDEOCODECTEXT}			= $media_info->{Mediainfo}->{File}->{track}->[1]->{Format};
	
		# supported values BLURAY, DVD, MKV, mpeg4, Mov, rmvb
		$provider_hash->{CONTAINERTEXT}					= lc($media_info->{Mediainfo}->{File}->{track}->[0]->{Format});
		$provider_hash->{MEDIAFORMAT}					= lc($media_info->{Mediainfo}->{File}->{track}->[0]->{Format});
		$provider_hash->{MEDIAFORMAT}					=~ s/Matroska/mkv/i;
		$provider_hash->{MEDIAFORMAT}					=~ s/avi/mpeg/i;
	
		$provider_hash->{MEDIAFORMATTEXT}			= uc($provider_hash->{MEDIAFORMAT});

		# supported values AAC51, AAC, AAC20, DD51, DD20, DTS51, MP3, FLAC, WMA, VORBIS, DTSHD, DTRUEHD
		my $audio_codec = lc($media_info->{Mediainfo}->{File}->{track}->[2]->{Format});
		my $channels=$media_info->{Mediainfo}->{File}->{track}->[2]->{Channel_s_};
		$channels =~ s/\D//g;

		if ($audio_codec =~ /dts/i) {
			if ($channels == 8) {$provider_hash->{SOUNDFORMAT} = "DTS71";}
			elsif ($channels == 7) {$provider_hash->{SOUNDFORMAT} = "DTS70";}
			elsif ($channels == 6) {$provider_hash->{SOUNDFORMAT} = "DTS51";}
			elsif ($channels == 5) {$provider_hash->{SOUNDFORMAT} = "DTS41";}
			elsif ($channels == 4) {$provider_hash->{SOUNDFORMAT} = "DTS40";}
			elsif ($channels == 3) {$provider_hash->{SOUNDFORMAT} = "DTS21";}
			elsif ($channels == 2) {$provider_hash->{SOUNDFORMAT} = "DTS20";}
			else {$provider_hash->{SOUNDFORMAT} = "DTS";}
		}
		elsif ($audio_codec =~ /aac/i) {
			if ($channels == 8) {$provider_hash->{SOUNDFORMAT} = "AAC71";}
			elsif ($channels == 7) {$provider_hash->{SOUNDFORMAT} = "AAC70";}
			elsif ($channels == 6) {$provider_hash->{SOUNDFORMAT} = "AAC51";}
			elsif ($channels == 5) {$provider_hash->{SOUNDFORMAT} = "AAC41";}
			elsif ($channels == 4) {$provider_hash->{SOUNDFORMAT} = "AAC40";}
			elsif ($channels == 3) {$provider_hash->{SOUNDFORMAT} = "AAC21";}
			elsif ($channels == 2) {$provider_hash->{SOUNDFORMAT} = "AAC20";}
			elsif ($channels == 1) {$provider_hash->{SOUNDFORMAT} = "AAC10";}
			else {$provider_hash->{SOUNDFORMAT} = "AAC";}
		}
		elsif ($audio_codec =~ /AC-3/i) {
			if ($channels == 8) {$provider_hash->{SOUNDFORMAT} = "DD71";}
			elsif ($channels == 7) {$provider_hash->{SOUNDFORMAT} = "DD70";}
			elsif ($channels == 6) {$provider_hash->{SOUNDFORMAT} = "DD51";}
			elsif ($channels == 5) {$provider_hash->{SOUNDFORMAT} = "DD41";}
			elsif ($channels == 4) {$provider_hash->{SOUNDFORMAT} = "DD40";}
			elsif ($channels == 3) {$provider_hash->{SOUNDFORMAT} = "DD21";}
			elsif ($channels == 2) {$provider_hash->{SOUNDFORMAT} = "DD20";}
			else {$provider_hash->{SOUNDFORMAT} = "DD";}
		}
		elsif ($audio_codec =~ /mpeg/i) {
			if ($channels == 2) {$provider_hash->{SOUNDFORMAT} = "MP320";}
			elsif ($channels == 1) {$provider_hash->{SOUNDFORMAT} = "MP310";}
			else {$provider_hash->{SOUNDFORMAT} = "MP3";}
		}
		else {
			$provider_hash->{SOUNDFORMAT}					=~ s/.*mpeg.*/All MPEG/i;
			# more search/replace as found.
		}
	
		# internal subtitles
		my @sub_ary=map{$_->{type} =~ /text/i ? $_->{Language} : () } @{$media_info->{Mediainfo}->{File}->{track}};
		$provider_hash->{SUBTITLES}=\@sub_ary;
		my $counter=1;
		Logger($config_options,sprintf("Found %d Subtitles",$#sub_ary),"DEBUG");

		foreach (@sub_ary) {
			$provider_hash->{"SUBTITLES$counter"}=lc($_);
			$counter++;
		}

		$provider_hash->{EXTERNALSUBTITLES}		= '';
		$provider_hash->{EXTERNALSUBTITLESTEXT}		= '';
	
		# figure out the resolution.
		# if the aspect ratio is 4:3 take the width/4*3 to get the resolution
		# if the aspect ratio is 16:9 its width/16*9 
		# else its something odd like 2.35:1 (still 16/9 more or less) just key off of the width
		# typical resolutions are
		#  288P 480I 480P 576I 576P 720I 720P 1080I 1080P

		my $suffix	= lc(substr($media_info->{Mediainfo}->{File}->{track}->[1]->{Scan_type},0,1)) ;
		my $width	= lc($media_info->{Mediainfo}->{File}->{track}->[1]->{Width}) ;
		$width =~ s/\D//g;

		if ($provider_hash->{ASPECTRATIOTEXT} eq "4:3" )  { 
			Logger($config_options,"Calculating Resolution for apectratio 4:3 width=$width suffix=$suffix","DEBUG");
			$provider_hash->{RESOLUTION} = sprintf ("%d%s",($width/4*3),$suffix); 
		} 
		elsif ($provider_hash->{ASPECTRATIOTEXT} eq "16x9" ) {
			Logger($config_options,"Calculating Resolution for apectratio 16:9 width=$width suffix=$suffix","DEBUG");
		 	$provider_hash->{RESOLUTION} = sprintf ("%d%s",($width/16*9),$suffix); 
		}
		elsif ($width == 1920) { 
			Logger($config_options,"Calculating Resolution for width=$width suffix=$suffix","DEBUG");
			$provider_hash->{RESOLUTION} = sprintf ("1080%s",$suffix); 
		}
		elsif ($width == 1280) { 
			Logger($config_options,"Calculating Resolution for width=$width suffix=$suffix","DEBUG");
			$provider_hash->{RESOLUTION} = sprintf ("720%s",$suffix); 
		}
		elsif ($width == 720) { 
			Logger($config_options,"Calculating Resolution for width=$width suffix=$suffix","DEBUG");
			$provider_hash->{RESOLUTION} = sprintf ("576%s",$suffix); 
		}
		elsif ($width == 640) { 
			Logger($config_options,"Calculating Resolution for width=$width suffix=$suffix","DEBUG");
			$provider_hash->{RESOLUTION} = sprintf ("480%s",$suffix); 
		}
		else { $provider_hash->{RESOLUTION} = "288p" ; }

		Logger($config_options,"Resolution has been determined to be ".$provider_hash->{RESOLUTION},"DEBUG");
	}
}


#---------------------------------------------------------------------------------------------
#
# Main
#
#---------------------------------------------------------------------------------------------

sub Usage {
# there must be exactly two command line arguments
#
# 1) full path to Template.xml
# 2) full path to Movie directory

	print STDERR<<EOF;

Usage: Thumbscanner [options] 
  -h  --help              print this usage and exit
  -r  --recurse           recursively scan subdirectories, default is no
  -d  --debug             print debugging information values < CRIT | ERROR | WARN | INFO | DEBUG >
  -f  --file              use a specific config file, default is engine.conf
  -o  --overwrite         overwrite existing moviesheets and thumbnails
  -i  --interactive       for instances where multiple hits are returned, prompt the user to pick one
  -t  --tgmd              prefer the use of tgmd file if found

Example:
  Thumbscanner -r -d INFO -o

	This will recurse subdirectories and overwrite existing moviesheets and thumbnails as well as printing debugging information at level INFO.
EOF
	exit 0;
}

sub ScanMovieDir {
	my $config_options=shift;
  my $workdir=shift; 

  my $startdir=&cwd; # keep track of where we began

  chdir($workdir) or die "Unable to enter dir $workdir:$!\n";
  opendir(DIR, ".") or die "Unable to open $workdir:$!\n";
	my @names=grep{ /^\w+/ && !/^\.+/ } readdir(DIR);
  closedir(DIR);
 
  foreach my $name (@names){
    if ( -d $name && ($config_options->{RECURSE} == 1) ){                     # is this a directory?
			Logger($config_options,"Entering Directory $name","DEBUG");
      ScanMovieDir($config_options,$name);
      next;
    }
		elsif ( -e $name && grep{ /.*\.avi$/i || /.*\.mkv$/i || /.*\.mov$/i || /.*\.mpg$/i || /.*\.mpeg$/i || /.*\.wmv$/i || /.*\.mp4$/i || /.*\.qt$/i || /.*\.rm$/i } $name) {
			my $moviesheet;
			my $thumbnail;
			my %provider_hash;

			$provider_hash{FULLMOVIEPATH}=&cwd."/$name";
			$provider_hash{MOVIEFILENAME}=$name;
			$provider_hash{MOVIEFILENAMEWITHOUTEXT}=$name;
			$provider_hash{MOVIEFILENAMEWITHOUTEXT} =~ s/\.\w+$//; # remove the trailing suffix
			Logger($config_options,"Processing $provider_hash{FULLMOVIEPATH} as a movie","DEBUG");
			Logger($config_options,"Creating a moviesheet for $provider_hash{MOVIEFILENAME}","INFO");
			
			my $clean_name=clean_name($provider_hash{MOVIEFILENAME});
			if ( ($config_options->{OVERWRITE}) || !( -e "$provider_hash{MOVIEFILENAMEWITHOUTEXT}.jpg"))  {
				# if a tgmd file exists, use it.
				if ( (-e "$provider_hash{FULLMOVIEPATH}.tgmd") && ($config_options->{PREFERTGMD} ) ) {
					Logger($config_options,"found TGMD file, using it.","INFO");
					$provider_hash{TGMD_FILE}="$provider_hash{FULLMOVIEPATH}.tgmd";
					GetMediaDetails_tgmd($config_options,\%provider_hash);
				}

				my $tmdb_id=GetTmdbID($config_options,\%provider_hash);
				unless (defined($tmdb_id)) {
					Logger($config_options,"unable to find movie data for $provider_hash{MOVIEFILENAME}","CRIT");
					next;
				}

				# get more detailed information using the Movie.getInfo call
				GetMediaDetails_tmdb($config_options,$tmdb_id,\%provider_hash);
				GetMediaDetails_imdb($config_options,\%provider_hash);
				if ($config_options->{COLLECTOR} =~ /moviemeter/i ) {
					Logger($config_options,"Using MOVIEMETER collector ","DEBUG");
					GetMediaDetails_moviemeter($config_options,\%provider_hash);
				}

				# get the media_info hash
				GetMediaInfo($config_options,\%provider_hash);

				# log the provider_hash;
				my $provider_string=Dumper(\%provider_hash);
				Logger ($config_options,$provider_string,"DEBUG");

				# start the movie sheet generation
				$moviesheet=generate_moviesheet($config_options, \%provider_hash);
				Logger($config_options,"Writing $provider_hash{FULLMOVIEPATH}_sheet.jpg","INFO");
				$moviesheet->Write("$provider_hash{FULLMOVIEPATH}_sheet.jpg");

				# generate thumbnail
				if ($provider_hash{COVER} ne "") {
					Logger($config_options,"Writing thumbnail","INFO");
					$thumbnail=grab_thumbnail(\%provider_hash);
					$thumbnail->Write("$provider_hash{MOVIEFILENAMEWITHOUTEXT}.jpg");
				}

				# if we used a tgmd, we need to clean up after ourselves.
				if (defined ($provider_hash{TGMD_FILE} ) ) {
					Logger($config_options,"Clean Up TGMD Temp directory ".$provider_hash{TGMD_TEMPDIR},"DEBUG");
					opendir(DIR, "$provider_hash{TGMD_TEMPDIR}") or die "Unable to open TGMD TEMPDIR  $provider_hash{TGMD_TEMPDIR}\n";
					my @names=grep{ !/^\.+/ } readdir(DIR);
					closedir(DIR);
					foreach (@names) {
        		Logger($config_options,"unlinking $provider_hash{TGMD_TEMPDIR}/$_","DEBUG");
						unlink "$provider_hash{TGMD_TEMPDIR}/$_";
					}
        	Logger($config_options,"removing directory $provider_hash{TGMD_TEMPDIR}","DEBUG");
					rmdir "$provider_hash{TGMD_TEMPDIR}";
					$provider_hash{TGMD_TEMPDIR}=undef;
					$provider_hash{TGMD_FILE}=undef;
				}

			}
  	}
	}
  chdir($startdir) or die "Unable to change to dir $startdir:$!\n";
}


sub Main {
	my $config_options=shift;

	# confirm that the movie directory and template file exist
	unless (-e $config_options->{TEMPLATE} && -f $config_options->{TEMPLATE} ) {
		Logger($config_options,"Template file '$config_options->{TEMPLATE}' does not exist!!","CRIT");
		exit -1;
	}
	unless (-e $config_options->{MOVIEPARENTFOLDER}) {
		Logger($config_options,"Movie directory '$config_options->{MOVIEPARENTFOLDER}' does not exist!!","CRIT");
		exit -1;
	}

	($config_options->{Template_Filename}, $config_options->{PATH}) = fileparse($config_options->{TEMPLATE});
	$config_options->{PATH} =~ s/\/$//;

	# there is no guarantee of case in Windows Filenaming.
	# we need to make sure we can load the file case insensitively.
	my @names = File::Finder->in($config_options->{PATH}."/..");
	$config_options->{names}=\@names;
	ScanMovieDir($config_options,$config_options->{MOVIEPARENTFOLDER});
}

my %config_options;
my $debug="WARN";
my $overwrite=0;
my $conf_file="engine.conf";
my $recurse=0;
my $tgmd=0;
my $interactive=0;
my $help=0;

my $results=GetOptions ("debug=s"				=> \$debug,
												"overwrite"			=> \$overwrite,
												"file=s"				=> \$conf_file,
												"help"					=> \$help,
												"interactive"		=> \$interactive,
												"tgmd"					=> \$tgmd,
												"recurse"				=> \$recurse);

Usage if $help;

# build up a hash with base information for this run
$config_options{DEBUG}=$debug;
$config_options{OVERWRITE}=$overwrite;
$config_options{CONF_FILE}=$conf_file;
$config_options{RECURSE}=$recurse;
$config_options{INTERACTIVE}=$interactive;
$config_options{PREFERTGMD}=$tgmd;
$config_options{VERSION}="v 0.6";
$config_options{BUILD_DATE}="Tue Jul 20 2010";

# read in the options in the config file
open (FD, $config_options{CONF_FILE}) or die "Unable to open config file $config_options{CONF_FILE}\n";
	while (my $line = <FD>) {
		chomp;
		if ($line =~ /^(\w+)=(.*)$/) {
			$config_options{$1}=$2;
		}
	}
close FD;
$config_options{LOGFILE} = ($config_options{LOGFILE} eq "") ? "/var/tmp/thumbscanner.log" : $config_options{LOGFILE};
unlink $config_options{LOGFILE};

my $tmp_string=Dumper(\%config_options);
Logger(\%config_options,$tmp_string,"DEBUG");

Main(\%config_options);
