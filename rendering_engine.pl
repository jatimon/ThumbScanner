#!/usr/bin/perl 

$|=1;

# imagemagick redering converter from thumbgens xml files

use strict;
use Image::Magick;
use XML::TokeParser;
use Data::Dumper;
use File::Basename;
use File::Finder;
use Math::Trig;
use XML::Bare;
use LWP::UserAgent;
use HTML::Entities;

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

	use vars qw($DEBUG);
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
	$color=GetColor($color);

# figure out the angle and offset
	if ( ($true_angle >= 270) && ($true_angle <= 360) ) {
		$angle = $true_angle-270;
		$dir_x = 1;
		$dir_y = 1;
	}
	elsif ( ($true_angle >= 180) && ($true_angle < 270) ) {
		$angle = $true_angle-1800;
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

	my $shadow_image=Image::Magick->new();
	$shadow_image=$base_image->Clone();
	$shadow_image->Set(background=>'none');
	$shadow_image->Shadow(opacity=>$opacity,sigma=>$softness,X=>0, Y=>0);

	my ($width, $height) = $base_image->Get('columns', 'rows');
	my $new_image=Image::Magick->new();
	$new_image->Set( size=>sprintf("%dx%d",$width+(abs($delta_x)*2), $height+abs($delta_y)));
	$new_image->Read('xc:none');
	$new_image->Composite(image=>$base_image, compose=>'src');


	if ($delta_x < 0) { $new_image->Roll(x=>abs($delta_x)) }
	$new_image->Composite(image=>$shadow_image, compose=>'dst-over',X=>$delta_x, Y=>$delta_y); 

	undef $base_image;
	undef $shadow_image;
	return $new_image;
}

sub GlassTable {
# emulate the glasstable effect with ImageMagick
	use vars qw($DEBUG);
	my $base_image=shift;
	my $x_offset=shift;
	my $y_offset=shift;
	my $opacity=shift;
	my $percent=shift;

	my ($width, $height) = $base_image->Get('columns', 'rows');
	my $first_image=Image::Magick->new();
	my $new_height=int($height*$percent/100);

	my $temp_image=Image::Magick->new();
	$temp_image=$base_image->Clone();
	$temp_image->Crop(sprintf("%dx%d+0+0", $width, $new_height) );
	$temp_image->Flip();

	my $temp_image2=Image::Magick->new();
	$temp_image2=$base_image->Clone();
	$temp_image2->Crop(sprintf("%dx%d+0+0", $width, $new_height) );
	$temp_image2->Flip();
	$temp_image2->Set(alpha=>'Extract');

	my $gradient=Image::Magick->new();
	$gradient->Set(size=>sprintf("%dx%d", $width, $new_height) );
	$gradient->Read("gradient:grey-black");

	$temp_image2->Composite(image=>$gradient, compose=>'Multiply');
	$temp_image2->Set(alpha=>'off');
	$temp_image->Set(alpha=>'off');

	$temp_image->Composite(image=>$temp_image2, compose=>'CopyOpacity');
	$temp_image->Set(alpha=>'on');
	
	$opacity=1-($opacity/100);
	$temp_image->Evaluate(value=>$opacity, operator=>'Multiply', channel=>'Alpha');

	my $clipboard=Image::Magick->new();
	push(@$clipboard, $base_image);
	push(@$clipboard, $temp_image);
	$base_image=$clipboard->Append();

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

	use vars qw($DEBUG);
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

sub PerspectiveView {
# create a perspectiveView of the passed in image
# initially this looks to be a trapezoid distort
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
	return Skew($orig_image, $angle, "True", "Vertical", "Trapezoid");
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

	# make a TopLeft Corner as a base and we will flip and flop as needed.
	my $points=sprintf("%d,%d %d,0",$roundness,$roundness,$roundness);
	$TopLeft->Set(size=>sprintf("%dx%d",$roundness,$roundness));
	$TopLeft->Read('xc:none');
	$TopLeft->Draw(primitive=>'circle', fill=>'white', points=>$points);

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

	if ( $border_width > 0 ) { 
	# this is what I am thinking here.  clone the image. resize it by borderwidth fill it with the bordercolor
	# lay the original image inside of the filled one.  The should give a border....
		my $border_image=Image::Magick->new(magick=>'png');
		$border_image=$base_image->Clone();
		($width, $height) = $base_image->Get('columns', 'rows');
		$border_color=GetColor($border_color);
		$border_image->Resize(width=>$width+(2*$border_width),height=>$height+(2*$border_width));
		$border_image->Set(background=>$border_color);
		$border_image->Shadow(opacity=>100,sigma=>0,X=>0, Y=>0);
		$border_image->Composite(image=>$base_image,compose=>'src-over',x=>$border_width,y=>$border_width);
		$base_image=$border_image;
		undef $border_image;
	}
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

	my $movie_xml=shift;
	my $mediainfo=shift;
	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $Template_Path=shift;
	my $template_xml=shift;
	my @Files=@_;
	my $sourceData;
	my $geometry=sprintf("%dx%d",$token->attr->{Width},$token->attr->{Height});
#my $temp=Image::Magick->new(geometry=>$geometry);
	my $temp=Image::Magick->new(magick=>'png');
		
		$sourceData=$token->attr->{SourceData};
		if ( $sourceData =~ /\%RATINGSTARS\%/ ) {
			# this token is part of the Settings token in the template.xml file
			my $source=$template_xml->{Template}->{Settings}->{Rating}->{FileName}->{value};
			next unless DeTokenize(\$source,$mediainfo,$movie_xml,$Template_Path,$template_xml,@Files);
			my $rating=$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{rating}->{value};
    	$temp->Read($source);
			my ($width, $height) = $temp->Get('columns', 'rows');
			# single star
			$temp->Crop(width=>$width/2,height=>$height);
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
			next unless DeTokenize(\$sourceData,$mediainfo,$movie_xml,$Template_Path,$template_xml,@Files);

			if ( $sourceData =~ /^http/i ) {
    		$temp->Read($sourceData);
			}
			else {
			my @newSource = grep {/$sourceData/i} @Files;
				$sourceData=$newSource[0] if $newSource[0] ne '';
				# check to make sure image file actually exists.  Otherwise Alert user and read xc:none
				if (-e $sourceData) {
    			$temp->Read($sourceData);
				}
				else {
					print "[31mERROR::[0m  [33mI could not find $sourceData[0m\n";
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
						my $opacity_percent=($token->attr->{Opacity}/100);
						print "Adjusting Opacity $sourceData by $opacity_percent \n" if $DEBUG ;
						# in ImageDraw, opacity ranges from 0 (fully transparent) to 100 (fully Opaque)
						$temp->Evaluate(value=>$opacity_percent, operator=>'Multiply', channel=>'All');
					}		
					elsif ( ($token->tag =~ /RoundCorners/i) && ($token->is_start_tag)  ) {
						print "Rounding Corners $sourceData\n" if $DEBUG  ;
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
					elsif ( ($token->tag =~ /PerspectiveView/i) && ($token->is_start_tag)  ) {
						print "Adjusting PerspectiveView $sourceData\n" if $DEBUG;
						$temp=PerspectiveView($temp,
							$token->attr->{Angle},
							$token->attr->{Orientation}
						);	
					}
					elsif ( ($token->tag =~ /Rotate/i) && ($token->is_start_tag)  ) {
						my $degrees=$token->attr->{Angle} * (-1);
						print "Rotating $sourceData by $degrees degrees\n" if $DEBUG ;
						my ($width, $height) = $temp->Get('columns', 'rows');
       			my @points=split(/[ ,]+/,sprintf("0,%d 100 %d",$height,$degrees));
						print $temp->Distort(method=>'ScaleRotateTranslate','best-fit'=>'False','virtual-pixel'=>'transparent',points=>\@points);
					}
					elsif ( ($token->tag =~ /DropShadow/i) && ($token->is_start_tag)  ) {
						print "Adding Shadow to $sourceData\n" if $DEBUG ;
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
			} # end Action If
		} # end While
	
		$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
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

	use vars qw($DEBUG);
	my $font=shift;

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

	print "[31mERROR::[0m  [33mthis font is not found ---- [01m$font_hash{Family}[0m\n" unless defined ($fonts[0]);
	undef $temp;

	if (scalar(@font_ary) > 5) {
		# build a string of which ever text options are specified
		my @options;
		push (@options, 'Italic') 		if $font_ary[3] =~ /True/i;

		$font_hash{Options}=join(',',@options);
		$font_hash{Family}.="-Bold" if $font_ary[2] =~ /True/i;
	}

	return \%font_hash;
}

sub GetGravity {
# ImageDraw alignment options, The text can be left-aligned, center-aligned, or right-aligned in both vertical and horizontal directions. 
	my $alignment=shift;

	my %alignment_hash = (
			'TopLeft'				=>	'NorthWest',
			'TopCenter'			=>	'North',
			'TopRight'			=>	'NorthEast',
			'Left'					=>	'West',
			'Right'					=>	'East',
			'BottomLeft'		=>	'SouthWest',
			'BottomMiddle'	=>	'South',
			'BottomRight'		=>	'SouthEast',
			'MiddleCenter'	=>	'Center',
		);

	return $alignment_hash{$alignment};
}
	

sub AddTextElement {
# Two basic types of text elements;
# 1) those with effect i.e. Action
# 2) those without

	use vars qw($DEBUG);
	my $movie_xml=shift;
	my $mediainfo=shift;
	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $Template_Path=shift;
	my $template_xml=shift;
	my @Files=@_;
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
	my $forecolor=GetColor($token->attr->{ForeColor});
	my $strokecolor=GetColor($token->attr->{StrokeColor});
	my $font_hash=ParseFont($token->attr->{Font});
	my $gravity=GetGravity($token->attr->{TextAlignment} );

	$string=$token->attr->{Text};
	if ($string =~ /\%.+\%/) {
		DeTokenize(\$string,$mediainfo,$movie_xml,$Template_Path,$template_xml,@Files);
	}


	my @text_attributes=$temp->QueryFontMetrics(text=>$string, fill=>$forecolor, font=>$font_hash->{Family}, pointsize=>$font_hash->{Size} ,antialias=>'True', gravity=>$gravity);
	if ($text_attributes[4] > $token->attr->{Width} ) {
		# time to wrap some text
		$string=TextWrap($string, $token->attr->{Width}, $font_hash->{Family}, $font_hash->{Size})
	}

	$temp->Annotate(text=>$string, fill=>$forecolor, font=>$font_hash->{Family}, pointsize=>$font_hash->{Size} ,antialias=>'True', gravity=>$gravity);

	$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
	undef $temp;
}

sub TextWrap {
# wrap some text
	my $string=shift;
	my $image_width=shift;
	my $family=shift;
	my $point=shift;

# the logic I am working with is render an image add text get metrics see if it fits
# rinse and repeat

	my $temp_img=Image::Magick->new(magick=>'png');
	my $new_text;
	my $running_text="";

	my @ary=split(/\s/,$string);

	foreach (@ary) {
  	$temp_img->Set(size=>sprintf("%dx100",$image_width));
  	$temp_img->Read('xc:none');
  	$temp_img->Annotate(text=>"$running_text $_",font=>$family,pointsize=>$point);
		if (($temp_img->QueryFontMetrics(text=>"$running_text $_",font=>$family,pointsize=>$point))[4] < $image_width ) {
  		$running_text="$running_text $_";
		}
		else {
			$new_text.="$running_text\n";
			$running_text=$_;
		}
  	@$temp_img=();
}
		$new_text.="$running_text\n";
			
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
	use vars qw($DEBUG);
	my $string=shift;  # the string where I replace the token
	my $media_info=shift;
	my $movie_xml=shift;
	my $Template_Path=shift;
	my $template_xml=shift;
	my @Files=@_;

	return 1 unless ($$string =~ /%/) ;

	print "Detokenizing $$string\n" if $DEBUG;

	if ($$string =~ /\%COUNTRIES\%/ ) {
		# determine Country information
		if (  ref($movie_xml->{OpenSearchDescription}->{movies}->{movie}->{countries}->{country}) =~ /hash/i) {
			$$string =~ s/\%COUNTRIES\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{countries}->{country}->{name}->{value}/;
		}
		else {
			$$string =~ s/\%COUNTRIES\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{countries}->{country}->[0]->{name}->{value}/;
		}
	}

	if ($$string =~ /\%YEAR\%/ ) {
		$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{released}->{value} =~ /.*(\d\d\d\d).*/;
		my $year=$1;
		$$string =~ s/\%YEAR\%/ $year/;
	}

	if ($$string =~ /\%.*TITLE\%/ ) {
		$$string =~ s/\%.*TITLE\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{name}->{value}/;
		if ( $$string =~ /\{(.+)\}/ ) {
			if ( $1 eq "UPPER" ) {
				$$string=uc($$string);
				$$string =~ s/\{UPPER\}//;
			}
			else {
				print "I have found a text modifier I don't recognize -- $1?\n";
			}
		}
	}

	if ($$string =~ /\%DURATIONTEXT\%/ ) {
		$$string =~ s/\%DURATIONTEXT\%/$media_info->{Mediainfo}->{File}->{track}->[1]->{Duration}/;
	}
	
	if ($$string =~ /\%FRAMERATETEXT\%/ ) {
		$$string =~ s/\%FRAMERATETEXT\%/$media_info->{Mediainfo}->{File}->{track}->[1]->{Frame_rate}/;
	}

	if ($$string =~ /\%ASPECTRATIOTEXT\%/ ) {
		$$string =~ s/\%ASPECTRATIOTEXT\%/$media_info->{Mediainfo}->{File}->{track}->[1]->{Display_aspect_ratio}/;
	}

	if ($$string =~ /\%VIDEOBITRATETEXT\%/ ) {
		$$string =~ s/\%VIDEOBITRATETEXT\%/$media_info->{Mediainfo}->{File}->{track}->[1]->{Bit_rate}/;
	}

	if ($$string =~ /\%AUDIOCHANNELSTEXT\%/ ) {
		$$string =~ s/\%AUDIOCHANNELSTEXT\%/$media_info->{Mediainfo}->{File}->{track}->[2]->{Channel_s_}/;
		$$string =~ s/(\d+) .*$/$1 ch/;
	}

	if ($$string =~ /\%AUDIOBITRATETEXT\%/ ) {
		$$string =~ s/\%AUDIOBITRATETEXT\%/$media_info->{Mediainfo}->{File}->{track}->[2]->{Bit_rate}/;
	}

	if ($$string =~ /\%FILESIZETEXT\%/ ) {
		$$string =~ s/\%FILESIZETEXT\%/$media_info->{Mediainfo}->{File}->{track}->[0]->{File_size}/;
	}

	if ($$string =~ /\%RATING\%/ ) {
		$$string =~ s/\%RATING\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{rating}->{value}/;
	}

	if ($$string =~ /\%PLOT\%/ ) {
		$$string =~ s/\%PLOT\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{overview}->{value}/;
	}

	if ($$string =~ /\%STUDIOS\%/ ) {
		# determine Studio information
		if (  ref($movie_xml->{OpenSearchDescription}->{movies}->{movie}->{studios}->{studio}) =~ /hash/i) {
			$$string =~ s/\%STUDIOS\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{studios}->{studio}->{name}->{value}/;
		}
		else {
			$$string =~ s/\%STUDIOS\%/$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{studios}->{studio}->[0]->{name}->{value}/;
		}
	}
    
  if ( $$string =~ /\%FANART.\%/ ) {
    my @fanart;
    # grab the fanart image from themoviedb
    foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
      push ( @fanart, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /original/i) && ($_->{type}->{value} =~ /backdrop/i) );
    }
		$$string =~ /(\d)/;
		my $fan_art_number=$1;
    if (scalar (@fanart) > $fan_art_number) {
      $$string =~ s/\%FANART.\%/$fanart[$fan_art_number]/;
    }
	}

    
  if ( $$string =~ /\%BACKGROUND\%/ ) {
    my @backdrops;
    # grab the backdrop image from themoviedb
    foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
      push ( @backdrops, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /original/i) && ($_->{type}->{value} =~ /backdrop/i) );
    }
    if (scalar (@backdrops) > 1) {
      # pick one randomly
      # $image_url=$backdrops[ rand @backdrops ];
      $$string =~ s/\%BACKGROUND\%/$backdrops[0]/;
    }
    else {
      $$string =~ s/\%BACKGROUND\%/$backdrops[0]/;
    }
	}

  if ( $$string =~ /\%COVER\%/ ) {
    my @covers;
    # grab the cover image from themoviedb
    foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
      push ( @covers, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /mid/i) && ($_->{type}->{value} =~ /poster/i) );
    }
    if (scalar (@covers) > 1) {
      # pick one randomly
      # $image_url=$covers[ rand @covers ];
      $$string =~ s/\%COVER\%/$covers[0]/;
    }
    else {
      $$string =~ s/\%COVER\%/$covers[0]/;
    }
  }

	if ($$string =~ /\%VIDEOFORMAT\%/ ) {
		my $rep;
		my $format=$media_info->{Mediainfo}->{File}->{track}->[1]->{Format};

		if ( $format =~ /mpeg-4/i ) { $format="Divx" }
		foreach (@{$template_xml->{Template}->{VideoFormats}->{VideoFormat} }) {
			$rep = $_->{Image}->{value} if $format =~  /$_->{Text}->{value}/i;
		}
		$$string =~ s/\%VIDEOFORMAT\%/$rep/;
	}

	if ($$string =~ /\%MEDIAFORMAT\%/ ) {
		my $rep;
		my $format=$media_info->{Mediainfo}->{File}->{track}->[0]->{Format};

		if ( $format =~ /Matroska/i ) { $format="mkv" }
		if ( $format =~ /avi/i ) { $format="mpeg" }
		foreach (@{$template_xml->{Template}->{MediaFormats}->{MediaFormat} }) {
			$rep = $_->{Image}->{value} if $format =~  /$_->{Text}->{value}/i;
		}
		$$string =~ s/\%MEDIAFORMAT\%/$rep/;
	}

	if ($$string =~ /\%RESOLUTION\%/ ) {
		my $rep=qw/%PATH%\..\Common\image_resolution\720.png/;
		$$string =~ s/\%RESOLUTION\%/$rep/;
	}

	if ($$string =~ /\%SOUNDFORMAT\%/ ) {
		# this is a bit more involved given the permutations of media formats
		my $format=$media_info->{Mediainfo}->{File}->{track}->[2]->{Format};
		my $format_version=$media_info->{Mediainfo}->{File}->{track}->[2]->{Format_version};
		my $channels=$media_info->{Mediainfo}->{File}->{track}->[2]->{Channel_s_};
		my $text;
		my $rep;

		if ( $format =~ /mpeg/i ) {
			if ( $format_version =~ /1/ ) {
				$text="MP3 1.0";
			}
			elsif ( $format_version =~ /2/ ) {
				$text="MP3 2.0";
			}
			else {
				$text="All Mpeg";
			}
		} else {
			if ( $format =~ /AC-3/i ) {
				$text="AAC Unknown";
			}
# still need to add different format versions.  Once I have more data from mediainfo output I can fill this in
		}
			# elses for other formats
		
		foreach (@{$template_xml->{Template}->{SoundFormats}->{SoundFormat} }) {
			$rep = $_->{Image}->{value} if $text =~  /$_->{Text}->{value}/i;
		}
		$$string =~ s/\%SOUNDFORMAT\%/$rep/;
	}

	if ($$string =~ /\%ACTORS\%/ ) {
		my @actors;
	  foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{cast}->{person} } ) {
      push (@actors, $_->{name}->{value}) if lc($_->{job}->{value}) eq "actor" ;
 		}   
	
		# we have an array of every director in this movie.  the template defines a max and a join character
		my $max=$template_xml->{Template}->{Settings}->{Actors}->{MaximumValues}->{value};
		my $join_char=$template_xml->{Template}->{Settings}->{Actors}->{Separator}->{value};

		# truncate the array if necessary
		$#actors=($max-1) if $#actors>$max;

		my $rep=join($join_char,@actors);
		$$string =~ s/\%ACTORS\%/$rep/;
	}

	if ($$string =~ /\%DIRECTORS\%/ ) {
		my @directors;
	  foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{cast}->{person} } ) {
      push (@directors, $_->{name}->{value}) if lc($_->{job}->{value}) eq "director" ;
 		}   
	
		# we have an array of every director in this movie.  the template defines a max and a join character
		my $max=$template_xml->{Template}->{Settings}->{Directors}->{MaximumValues}->{value};
		my $join_char=$template_xml->{Template}->{Settings}->{Directors}->{Separator}->{value};

		# truncate the array if necessary
		$#directors=($max-1) if $#directors>$max;

		my $rep=join($join_char,@directors);
		$$string =~ s/\%DIRECTORS\%/$rep/;
	}

	if ($$string =~ /\%GENRES\%/ ) {
		my @genres;

		if (  ref($movie_xml->{OpenSearchDescription}->{movies}->{movie}->{categories}->{category} ) =~ /hash/i) {
      push (@genres, $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{categories}->{category}->{name}->{value}) if lc($movie_xml->{OpenSearchDescription}->{movies}->{movie}->{categories}->{category}->{name}->{value}) eq "genre" ;
		}
		else {
			foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{categories}->{category} } ) {
      	push (@genres, $_->{name}->{value}) if lc($_->{type}->{value}) eq "genre" ;
    	}
		}

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
		$$string =~ s/\%PATH\%/$Template_Path/;
		$$string =~ tr |\\|/|;
		print "Path expanded -> $$string\n" if $DEBUG;
	}

	if ($$string =~ /\%.+\%/ ) {
		# add some color so this stands out
		print "[33mUnable to Detokenize -> $$string [0m \n" if $DEBUG;
		return 0;
	} 
	return 1;

}

sub generate_moviesheet {
# takes as input a movie data hash, a template file and the filenamed array
	my $movie_xml=shift;
	my $mediainfo=shift;
	my $template=shift;
	my $Template_Path=shift;
	my @Files=@_;

	my $parser = XML::TokeParser->new( $template );
	my $template_obj = new XML::Bare(file => "$Template_Path/Template.xml" );
	my $template_xml=$template_obj->parse();

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
		$moviesheet->ReadImage('xc:black'); # make a white canvas
    }

		# add an image element to the canvas
    if ( ($token->tag eq "ImageElement") && ($token->is_start_tag)  ) {
      print "ImageElement\n" if $DEBUG;
			AddImageElement($movie_xml,$mediainfo,$moviesheet,$token,$parser,$Template_Path,$template_xml,@Files);
    }

		# add a text element to the canvas
    if ( ($token->tag eq "TextElement") && ($token->is_start_tag)  ) {
      print "TextElement\n" if $DEBUG;
			AddTextElement($movie_xml,$mediainfo,$moviesheet,$token,$parser,$Template_Path,$template_xml,@Files);
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

sub GetTmdbID {
# passed in the file name, clean it and return the tmdb_id
	my $file_name = shift;
	my $tmdb_id;

	if ($file_name =~ /tmdb_id=(.*)\..*$/) {
		return ($1);
	}

	# the file name does not contain the tmdb_id.  so let's query tmdb's api and get the filename
	# N.B. here would be a possible injection point to allow the user to select a specific movie should
	# the results from tmdb's api have multiple hits.
	my $movie_name=clean_name($file_name);
	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->env_proxy;

	my $response = $ua->get("http://api.themoviedb.org/2.1/Movie.search/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/$movie_name");
	my $xml_ob = new XML::Bare(text => $response->decoded_content );
	my $xml_root=$xml_ob->simple();

	if ( $xml_root->{OpenSearchDescription}->{'opensearch:totalResults'} > 1 ) {
		print "WARNING: Multiply movie entries for this title\n" ;
		print "\tthis can be fixed by adding the string tmdb_id=<the ID> to the filename\n\t i.e. 21.avi becomes 21tmdb=8065.avi to ensure we get the Kevin Spacey one\n";
		$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->[0]->{id};
	}
	else {
		$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->{id};
	}
	return $tmdb_id;
}	

sub GetMediaDetails {
# grab the xml data for this specific movie from themoviedb.org
# store it in a xml object so we can pull data from it as we build the moviesheet
	my $tmdb_id=shift;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->env_proxy;

	my $response = $ua->get("http://api.themoviedb.org/2.1/Movie.getInfo/en/xml/79302e9ad1a5d71e8d62a82334cdbda4/$tmdb_id");
	my $xml_data=decode_entities($response->decoded_content);
	my $xml_ob = new XML::Bare(text => $xml_data );
	my $xml_root=$xml_ob->parse();

	return $xml_root;
}

sub GetMediaInfo {
# call the shell program mediainfo on $actual_file_name and return a hash reference to it
	my $movie_name=shift;

	# I really hate doing it this way.  At some point it would be great to talk direct to the library
	# some effort should be put into ensuring that $movie_name is safe
  open my $FD, "mediainfo --Output=XML '$movie_name' |" or die "unable to open $movie_name";
  my @xml=<$FD>;
  close $FD;

  my $ob = new XML::Bare(text => "@xml" );
  return $ob->simple();
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

# generic debugging information.  probably replaced later with command line argument
our $DEBUG=0;

my $moviesheet;

opendir DIR, $movie_directory || die "Unable to open Movie Directory";
	my @movies=grep{ /^\w+/ && !/^\.+/ && !/jpg/ && -f "$movie_directory/$_" } readdir(DIR);
closedir DIR;

foreach (@movies) {
	chomp;
	print "Creating a moviesheet for $_\n";
	my $actual_file_name = $_;
	my $tmdb_id=GetTmdbID($actual_file_name);
	# get the media_info hash
	my $mediainfo=GetMediaInfo("$movie_directory/$actual_file_name");
	$actual_file_name =~ s/\.\w+$//; # remove the trailing suffix

	if ( !( -e "$movie_directory/$actual_file_name.jpg") && (defined($tmdb_id)) ) {
		# get more detailed information using the Movie.getInfo call
		my $xml_root=GetMediaDetails($tmdb_id);
		# start the movie sheet generation
 		$moviesheet=generate_moviesheet($xml_root, $mediainfo, $template, $Template_Path, @names);
	}
	else {
		print "unable to find movie data for $_\n";
	}
	print "Writing ${_}_sheet.jpg\n" ;
	$moviesheet->Write("${_}_sheet.jpg");

}
