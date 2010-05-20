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
use XML::Bare;
use LWP::UserAgent;

#use Text::Wrap;
#use HTML::Entities;
#
#$Text::Wrap::initial_tab = "\t";    # Tab before first line
#$Text::Wrap::subsequent_tab = "";   # All other lines flush left
#$Text::Wrap::columns = 40;

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
		print "sourceData -----> $sourceData\n";
		if ( $sourceData =~ /\%PATH\%/ ) {
			# fix the source, it will come in Window Path Format, switch it to Unix

#TODO much of this information will come from mediainfo

			$sourceData =~ s/\%PATH\%/$Template_Path/;
			$sourceData =~ tr |\\|/|;

			next if ($sourceData =~ /SUBTITLES/ );
			next if ($sourceData =~ /CERTIFICATION/ );
			next if ($sourceData =~ /STUDIOS/ );

			my @newSource = grep {/$sourceData/i} @Files;
			$sourceData=$newSource[0];
			$temp->Read($sourceData) if defined($sourceData);
		} 
		elsif ( $sourceData =~ /\%BACKGROUND\%/ ) {
			my $image_url;
			my @backdrops;
			$sourceData="BACKGROUND";
			# grab the backdrop image from themoviedb
			foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
  			push ( @backdrops, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /original/i) && ($_->{type}->{value} =~ /backdrop/i) );
			}
			if (scalar (@backdrops) > 1) {
				# pick one randomly
				$image_url=$backdrops[int(rand(scalar(@backdrops)))];
			}
			else {
				$image_url=$backdrops[0];
			}
			$temp->Read($image_url);
		}	
		elsif ( $sourceData =~ /\%COVER\%/ ) {
			$sourceData="COVER";
			my $image_url;
			my @covers;
			# grab the cover image from themoviedb
			foreach (@{ $movie_xml->{OpenSearchDescription}->{movies}->{movie}->{images}->{image} } ) {
				push ( @covers, $_->{url}->{value}) if ( ($_->{size}->{value} =~ /mid/i) && ($_->{type}->{value} =~ /poster/i) );
			}
			if (scalar (@covers) > 1) {
				# pick one randomly
				$image_url=$covers[int(rand(scalar(@covers)))];
			} 
			else {
				$image_url=$covers[0];
			} 
			print "image url $image_url\n" ;
			$temp->Read($image_url);
		}
		else {
			print "what do I do with $sourceData\n"; 
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
		}
	}
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

	my %font_hash=(
			'Family'		=>	"$font_ary[0]",
			'Size'			=>	$font_ary[1],
			'Unit'			=>	scalar(@font_ary) > 5 ?	$font_ary[6] : $font_ary[2],
	);

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
#
	use vars qw($DEBUG);

	my $movie_xml=shift;
	my $base_image=shift;
	my $token=shift;
	my $parser=shift;
	my $Template_Path=shift;
	my @Files=@_;
	my $sourceData;
	my $text;

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

	if ($token->attr->{Text} =~ /%/) {
		print "Do substitution for ".$token->attr->{Text}."\n";
			my $temp=uc($movie_xml->{OpenSearchDescription}->{movies}->{movie}->{name}->{value});
			$text=$token->attr->{Text};
			$text =~ s/\%.+\%/$temp/;
	}
	else {
		$text=$token->attr->{Text};
	}

print "it is now ------->$text\n";

	print "pointsize=$font_hash->{Size}\n";

#$temp->Annotate(text=>$text, fill=>$forecolor, stroke=>$strokecolor, font=>$font_hash->{Family},
	$temp->Annotate(text=>$text, fill=>$forecolor, stroke=>$strokecolor, font=>$font_hash->{Family}, pointsize=>$font_hash->{Size},strokewidth=>$token->attr->{StrokeWidth} ,antialias=>'True', gravity=>$gravity);

	while( defined( $token = $parser->get_token() ) ){
		if ( ($token->is_tag) && ($token->is_end_tag) && ($token->tag =~ /TextElement/) ) {
			 last;
		}
		elsif ($token->tag =~ /Actions/ ) {
			# do some actions
		}
	}
	$base_image->Composite(image=>$temp, compose=>'src-atop', geometry=>$geometry, x=>$composite_x, y=>$composite_y);
	undef $temp;
}

#---------------------------------------------------------------------------------------------
#
# Movie Sheet Generation
#
#---------------------------------------------------------------------------------------------

sub generate_moviesheet {
# takes as input a movie data hash, a template file and the filenamed array
	my $movie_xml=shift;
	my $template=shift;
	my $Template_Path=shift;
	my @Files=@_;

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
		$moviesheet->ReadImage('xc:black'); # make a white canvas
    }

		# add an image element to the canvas
    if ( ($token->tag eq "ImageElement") && ($token->is_start_tag)  ) {
      print "ImageELement\n" if $DEBUG;
			AddImageElement($movie_xml,$moviesheet,$token,$parser,$Template_Path,@Files);
    }

		# add a text element to the canvas
    if ( ($token->tag eq "TextElement") && ($token->is_start_tag)  ) {
			AddTextElement($movie_xml,$moviesheet,$token,$parser,$Template_Path,@Files);
    }
	}
	$moviesheet->Write("$movie_xml->{OpenSearchDescription}->{movies}->{movie}->{name}->{value}.jpg");
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
		print "WARNING: Multiply movie entries for this title\n";
		$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->[0]->{id};
	}
	else {
		$tmdb_id=$xml_root->{OpenSearchDescription}->{movies}->{movie}->{id};
	}

	print "tmdb=$tmdb_id\n";
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
	my $xml_ob = new XML::Bare(text => $response->decoded_content );
	my $xml_root=$xml_ob->parse();

	return $xml_root;
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

opendir DIR, $movie_directory || die "Unable to open Movie Directory";
	my @movies=grep{ /^\w+/ && !/^\.+/ && !/jpg/ && -f "$movie_directory/$_" } readdir(DIR);
closedir DIR;

foreach (@movies) {
	chomp;
	my $actual_file_name = $_;
	my $tmdb_id=GetTmdbID($actual_file_name);
	$actual_file_name =~ s/\.\w+$//; # remove the trailing suffix

	if ( !( -e "$movie_directory/$actual_file_name.jpg") && (defined($tmdb_id)) ) {
		# get more detailed information using the Movie.getInfo call
		my $xml_root=GetMediaDetails($tmdb_id);
		# start the movie sheet generation
 		generate_moviesheet($xml_root, $template, $Template_Path, @names);
	}
	else {
		print "unable to find movie data for $_\n";
	}
}
