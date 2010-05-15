#!/usr/bin/perl -w

$|=1;

# imagemagick redering converter from thumbgens xml files

use strict;
use Image::Magick;
use XML::TokeParser;
use Data::Dumper;
use File::Basename;
use File::Finder;
use Math::Trig;

sub DropShadow {
# add a shadow to the image
	use vars qw($DEBUG);
	my $base_image=shift;
	my $angle=shift;
	my $color=shift;
	my $distance=shift;
	my $opacity=shift;
	my $softness=shift;

# get actual color translation
	$color=GetColor($color);

print "\n\t\t\tcolor->$color\n\n";

	my $shadow_image=Image::Magick->new();
	my $mosaic_image=Image::Magick->new();
	$base_image->Display(":0.0");
	my $geometry=sprintf("%dx%d",$base_image->Get('columns', 'rows') );
	$shadow_image=$base_image->Clone();
	$shadow_image->Set(background=>$color);
	$shadow_image->Shadow(geometry=>$geometry,x=>$distance,y=>$distance,opacity=>$opacity,sigma=>$softness);
	$shadow_image->Set(background=>'none');

	push(@$shadow_image,$base_image);
	print $mosaic_image=$shadow_image->Mosaic();

	$shadow_image->Display(":0.0");
	$mosaic_image->Display(":0.0");
	undef $base_image;
	undef $shadow_image;
	return $mosaic_image;


}

sub GlassTable {
# emulate the glasstable effect with ImageMagick
	use vars qw($DEBUG);
	my $base_image=shift;
	my $x_offset=shift;
	my $y_offset=shift;
	my $opacity=shift;
	my $percent=shift;

# let's try it with shell drops, I can't seem to get perlMagick to pull this off.

	my ($width, $height) = $base_image->Get('columns', 'rows');
	my $first_image=Image::Magick->new();
	my $new_height=int($height*$percent/100);

	print "Opacity -> $opacity\n" if $DEBUG;

	my $shell_cmd="convert /tmp/source \\( -clone 0 -flip -crop ${width}x${new_height}+0+0 +repage \\) \\( -clone 0 -alpha extract -flip -crop ${width}x${new_height}+0+0 +repage -size ${width}x${new_height} gradient: +level 0x${opacity}% -compose multiply -composite \\) \\( -clone 1 -clone 2 -alpha off -compose copy_opacity -composite \\) -delete 1,2 -channel rgba -alpha on -append /tmp/glass.png";

	print "CMD->$shell_cmd\n" if $DEBUG;

	$base_image->Write("/tmp/source");
	
	my $new_image=Image::Magick->new();
	system($shell_cmd);
	$new_image->Read("/tmp/glass.png");
	unlink ("/tmp/glass.png");

	return $new_image;

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
#
	use vars qw($DEBUG);
	my $orig_image=shift;
	my $angle=shift;
	my $contrainProportions=shift;
	my $orientation=shift;
	my $type=shift;
	my @skew_points;

	if ( $type =~ /Parallelogram/i ) {
		# Let's deal with Parallelogram first.  
		if ( $orientation =~ /Vertical/i ) {
			# In the Vertical, +ve angle implies left side shifts down -ve implies right side shifts down
			# simple Parallelogram means we simply use the angle to figure out the delta up or down
			# of the right side of the image.  That means math TAN $angle = Delta / image width

			my ($width, $height) = $orig_image->Get('columns', 'rows');
			my $direction=$angle/abs($angle); # this give either 1 or -1
			my $angle=abs($angle);
			my $delta=(tan(deg2rad($angle) )*$width) * $direction; # tan A = sin A / cos A
			if ( $direction < 0 ) {	
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d 0,%d   %d,0 %d,%d   %d,%d %d,%d", #top left no move
					$height, $height, # bottom left does not move
					$width, $width, $delta, # top right slides down
					$width, $height, $width, $height+$delta, # bottom right slides down
					) 
				);
			}
			else {
				@skew_points=split(/[ ,]+/,sprintf("0,0 0,%d   0,%d 0,%d   %d,0 %d,0   %d,%d %d,%d", $delta, # top left slides down
					$height, $height+$delta, # bottom left slides down
					$width, $width,  # top right stays the same
					$width, $height, $width, $height # bottom right stays the same
					) 
				);
			}
			$orig_image->Distort(points=>\@skew_points, "method"=>"Perspective", 'virtual-pixel'=>'transparent');
		}
		else {  # its Horizontal Parallelogram
			# In the Horizontal, +ve angle implies bottom of image shifts right -ve implies top shifts right
      	my ($width, $height) = $orig_image->Get('columns', 'rows');
      	my $direction=$angle/abs($angle); # this give either 1 or -1
      	my $angle=abs($angle);
      	my $delta=(tan(deg2rad($angle) )*$width) * $direction; # tan A = sin A / cos A
      	if ( $direction < 0 ) {
        	@skew_points=split(/[ ,]+/,sprintf("0,0 %d,0   0,0 0,0   %d,0 %d,0   %d,%d %d,%d", $delta, #top left slides right
          	# bottom left does not move
          	$width, $width+$delta, # top right slides right
          	$width, $height, $width, $height # bottom right does not move
          	));
      	}
      	else {
        	@skew_points=split(/[ ,]+/,sprintf("0,0 0,0   0,%d %d,%d   %d,0 %d,0   %d,%d %d,%d",  # top left does not move
          	$height, $delta, $height, # bottom left slides right
          	# top right stays the same
          	$width, $height, $width+$delta, $height # bottom right slides right
          	));
      	}
     	$orig_image->Distort(points=>\@skew_points, "method"=>"Perspective", 'virtual-pixel'=>'transparent');
    }
	}
	else { # this is the trapezoid distort


	}
}


sub RoundCorners {
	use vars qw($DEBUG);
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
	$base_image->Composite(image=>$white, compose=>'SrcIn');
	$base_image->Set(alpha=>'Deactivate');

#$roundness=$roundness*2;
	$roundness=$roundness*3;
	# make a TopLeft Corner as a base and we will flip and flop as needed.
	my $points=sprintf("%d,%d %d,0",$roundness,$roundness,$roundness);
	$TopLeft->Set(size=>sprintf("%dx%d",$roundness,$roundness));
	$TopLeft->Read('xc:none');
	$TopLeft->Draw(primitive=>'circle', fill=>'white', points=>$points);


print "------------------------------------------------------------------------------Corners = $corners\n" if $DEBUG;

	if ( ($corners =~ /topleft/i ) || ( $corners =~ /All/i ) ) {
		# make a TopLeft overlay
		print "TopLeft\n" if $DEBUG;
		$base_image->Composite(compose=>'dst-atop',image=>$TopLeft,gravity=>'NorthWest');
	}
	if ( ( $corners =~ /topright/i ) || ( $corners =~ /All/i ) ) {
		# make a TopRight overlay
		my $TopRight=Image::Magick->new(magick=>'png');
		$TopRight=$TopLeft->Clone();
		$TopRight->Flop();
		print "TopRight\n" if $DEBUG;
		$base_image->Composite(compose=>'dst-atop',image=>$TopRight,gravity=>'NorthEast');
		undef $TopRight;
  }
  if( ( $corners =~ /bottomright/i ) || ( $corners =~ /All/i ) ) {
    # make a BottomRight overlay
		my $BottomRight=Image::Magick->new(magick=>'png');
		$BottomRight=$TopLeft->Clone();
		$BottomRight->Flop();
		$BottomRight->Flip();
		print "BottomRight\n" if $DEBUG;
		$base_image->Composite(compose=>'dst-atop',image=>$BottomRight,gravity=>'SouthEast');
		undef $BottomRight;
  }
  if( ( $corners =~ /bottomleft/i ) || ( $corners =~ /All/i ) ) {
	  # make a BottomLeft overlay
		my $BottomLeft=Image::Magick->new(magick=>'png');
		$BottomLeft=$TopLeft->Clone();
		$BottomLeft->Flip();
		print "BottomLeft\n" if $DEBUG;
		$base_image->Composite(compose=>'dst-atop',image=>$BottomLeft,gravity=>'SouthWest');
		undef $BottomLeft;
  }

	$base_image->Set(alpha=>'Activate');
	$base_image->Composite(image=>$orig_image, compose=>'src-in');
	undef $TopLeft;
	undef $orig_image;
	return $base_image;
}

sub GetColor {
# take the signed int that ImageDraw uses and return a hex.  When converted from signed int to hex
# ImageDraw uses the following convention  AARRGGBB  Alpha Red Green Blue.  ImageMagick like
# RRGGBBAA so lets pass back a hash reference.
	my $ID_color=shift;

	my $hex = sprintf ("%x",$ID_color);

	my $alpha= substr($hex,0,2);
	my $red= substr($hex,2,2);
	my $green= substr($hex,4,2);
	my $blue= substr($hex,6,2);

	return "#$red$green$blue$alpha\n";
}

sub AddImageElement {
# take the base image and laydown a composite on top
# all of the composite information will be in the composite_data variable
	use vars qw($DEBUG);

	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $Template_Path=shift;
	my @Files=@_;
	my $sourceData;
	my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
	my $temp=Image::Magick->new(geometry=>$geometry);
		
	if ( $token->attr->{Source} eq "File" ) {

		# File Sources are two types;
		#	1) path to file
		# 2) variable reference to downloaded content

		$sourceData=$token->attr->{SourceData};
		if ( $sourceData =~ /\%PATH\%/ ) {
			# fix the source, it will come in Window Path Format, switch it to Unix
			$sourceData =~ s/\%PATH\%/$Template_Path/;
			$sourceData =~ s/\%CERTIFICATION\%/PG/;
			$sourceData =~ s/\%STUDIOS\%/Happy Madison Productions/;
			$sourceData =~ s/\%SUBTITLES1\%/wales/;
			$sourceData =~ s/\%EXTERNALSUBTITLES1\%/wales/;
			$sourceData =~ s/\%SUBTITLES2\%/wales/;
			$sourceData =~ s/\%EXTERNALSUBTITLES2\%/wales/;
			$sourceData =~ s/\%SUBTITLES3\%/wales/;
			$sourceData =~ s/\%EXTERNALSUBTITLES3\%/wales/;
			$sourceData =~ s/\%SUBTITLES4\%/wales/;
			$sourceData =~ s/\%EXTERNALSUBTITLES4\%/wales/;
			$sourceData =~ s/\%SUBTITLES5\%/wales/;
			$sourceData =~ s/\%EXTERNALSUBTITLES5\%/wales/;
			$sourceData =~ tr |\\|/|;

			my @newSource = grep {/$sourceData/i} @Files;
			$sourceData=$newSource[0];
			$temp->Read($sourceData) if defined($sourceData);
		} 
		elsif ( $sourceData =~ /\%BACKGROUND\%/ ) {
			$sourceData='./Movies/Avatar.avi_sheet.jpg';
			$temp->Read('./Movies/Avatar.avi_sheet.jpg');
		}	
		elsif ( $sourceData =~ /\%COVER\%/ ) {
			$sourceData='./Movies/Avatar.jpg';
			$temp->Read('./Movies/Avatar.jpg');
		}
		else { die "what do I do with $sourceData\n"; }

		$temp->Resize(width=>$token->attr->{Width}, height=>$token->attr->{Height});
	}

	# because we are stream parsing the xml data we need to remember when on the canvas to composite this image
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
					print "Cropping $sourceData\n" if $DEBUG;
					$temp->Crop(width=>$token->attr->{Width},  
						height=>$token->attr->{Height},  
						x=>$token->attr->{X},  
						y=>$token->attr->{Y} );
				}
				elsif ( ($token->tag =~ /GlassTable/i) && ($token->is_start_tag)  ) {
					print "glasstabling $sourceData\n" if $DEBUG;
					$temp=GlassTable($temp,
						$token->attr->{ReflectionLocationX},
						$token->attr->{ReflectionLocationY},
						$token->attr->{ReflectionOpacity}, 
						$token->attr->{ReflectionPercentage});
				}
				elsif ( ($token->tag =~ /AdjustOpacity/i) && ($token->is_start_tag)  ) {
					print "Adjusting Opacity $sourceData\n" if $DEBUG;
					# I have arrived at the conclusion that in this case Opacity is percentage of transparency.
					#				# so let's go with that
					my $transparency=($token->attr->{Opacity}/100);
					$temp->Evaluate(value=>$transparency, operator=>'Multiply', channel=>'Alpha');
				}		
				elsif ( ($token->tag =~ /RoundCorners/i) && ($token->is_start_tag)  ) {
					print "Rounding Corners $sourceData\n" if $DEBUG ;
       		$temp=RoundCorners($temp,
       			$token->attr->{BorderColor},
       			$token->attr->{BorderWidth},
       			$token->attr->{Roundness},
       			$token->attr->{Corners});
				}
				elsif ( ($token->tag =~ /AdjustSaturation/i) && ($token->is_start_tag)  ) {
					my $level=($token->attr->{Level} * 255)/100; # imagemagick saturation is range 0-255 
					print "Adjusting Saturation level $level $sourceData\n" if $DEBUG ;
					$temp->Modulate(saturation=>$level );
				}
				elsif ( ($token->tag =~ /AdjustBrightness/i) && ($token->is_start_tag)  ) {
					my $level=($token->attr->{Level} * 255)/100; # imagemagick brightness is range 0-255 
					print "Adjusting brightness level $level $sourceData\n" if $DEBUG ;
					$temp->Modulate(brightness=>$level );
				}
				elsif ( ($token->tag =~ /Rotate/i) && ($token->is_start_tag)  ) {
					print "Rotating $sourceData\n" if $DEBUG ;
					$temp->Rotate(degrees=>$token->attr->{Angle} );
				}
				elsif ( ($token->tag =~ /DropShadow/i) && ($token->is_start_tag)  ) {
					print "Adding Shadow to $sourceData\n"  ;
					$temp=DropShadow($temp,
						$token->attr->{Angle},
						$token->attr->{Color},
						$token->attr->{Distance},
						$token->attr->{Opacity},
						$token->attr->{Softness}
					);
				}
				elsif ( ($token->tag =~ /Skew/i) && ($token->is_start_tag)  ) {
					print "Skewing $sourceData\n" if $DEBUG ;
					printf ("options angle %d\ncontrain %s\norient %s\ntype %s\n", $token->attr->{Angle},$token->attr->{ConstrainProportions}, $token->attr->{Orientation},$token->attr->{Type});

					$temp=Skew($temp,
					$token->attr->{Angle},
					$token->attr->{ConstrainProportions},
					$token->attr->{Orientation}, 
					$token->attr->{Type});
				}
				elsif ( ($token->tag =~ /Flip/i) && ($token->is_start_tag)  ) {
					print "Flipping/Flopping $sourceData\n" if $DEBUG ;
					if ( $token->attr->{Type} =~ /Horizontal/i ) { 
						$temp->Flip();
					}
					else {
						$temp->Flop();
					}
				}
				else {
					if ( ( $token->tag ) && ( $token->is_start_tag ) ) {
						print "don't know what to do with " . $token->tag . "\n";;
					}
				}
				last if ( ($token->tag =~ /Actions/) );
			}
		}
	}
			$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
			undef $temp;
}


sub Usage {
# there must be exactly two command line arguments
#
# 1) full path to Template.xml
# 2) full path to Movie directory

	print STDERR "Usage:\n\n";
	print STDERR "\t $0 <path to Template.xml> <path to Movie directory>\n\n";
	print STDERR "\t i.e. $0 /samba_mount/media/templates/Dribblers_cool_template /samba_mount/media/movies\n\n";
	exit 0;
}

Usage unless ($#ARGV == 1);

my $template=$ARGV[0];
my $movie_directory=$ARGV[1];

my ($Template_Filename, $Template_Path) = fileparse($template);
$Template_Path =~ s/\/$//;

# there is no guarantee of case in Windows Filenaming.
# we need to make sure we can load the file case insensitively.
my @names = File::Finder->in("$Template_Path/..");

our $DEBUG=0;
#
# read in an parse a Template.xml file.  
# 
# the final goal is to be able to use thumbgen templates to make moviesheets
#

my $parser = XML::TokeParser->new( $template );
my $moviesheet;


while( defined( my $token = $parser->get_token() ) ){
    if ( ($token->tag =~ /ImageDrawTemplate/ ) && ($token->is_start_tag) ) {
      print "---> imagedrawtemplate <---\n";
    }

    if ( ($token->tag eq "Canvas") && ($token->is_start_tag) ) {
      printf ("create a canvas of width=%d and height=%d\n",$token->attr->{Width},$token->attr->{Height}) if $DEBUG;
		# Create a Canvas

		my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
		$moviesheet=Image::Magick->new(size=>$geometry); # invoke new image
		$moviesheet->ReadImage('xc:white'); # make a white canvas
    }

    if ( ($token->tag eq "ImageElement") && ($token->is_start_tag)  ) {
      print "ImageELement\n" if $DEBUG;
			AddImageElement($moviesheet,$token,$parser,$Template_Path,@names);
    }
}



$moviesheet->Display(':0.0');


